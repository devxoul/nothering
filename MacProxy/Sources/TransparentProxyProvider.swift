import Darwin
import Network
import NetworkExtension
import os
import PhoneLink

/// Receives app TCP flows from macOS and relays each one to the iPhone's SOCKS5 proxy.
final class TransparentProxyProvider: NETransparentProxyProvider {
  private let logger = Logger(subsystem: "app.nothering", category: "proxy")
  /// The menu bar app's forwarder, which owns the USB / hotspot link to the phone.
  private static let forwarderPort: UInt16 = 11080

  /// Destinations that must never go through the phone: LAN, link-local (the hotspot link itself),
  /// 464XLAT, CGNAT/Tailscale and unique-local ranges.
  private static let excludedNetworks: [(String, Int)] = [
    ("10.0.0.0", 8), ("172.16.0.0", 12), ("192.168.0.0", 16), ("169.254.0.0", 16),
    ("100.64.0.0", 10), ("192.0.0.0", 24), ("fe80::", 10), ("fc00::", 7),
  ]

  private let reachability = PhoneReachability(forwarderPort: forwarderPort)

  override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
    let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.includedNetworkRules = [
      NENetworkRule(
        remoteNetworkEndpoint: nil, remotePrefix: 0,
        localNetworkEndpoint: nil, localPrefix: 0, protocol: .TCP, direction: .outbound
      ),
    ]
    settings.excludedNetworkRules = Self.excludedNetworks.map { address, prefix in
      NENetworkRule(
        remoteNetworkEndpoint: .hostPort(host: Network.NWEndpoint.Host(address), port: 0), remotePrefix: prefix,
        localNetworkEndpoint: nil, localPrefix: 0, protocol: .TCP, direction: .outbound
      )
    }
    reachability.start()
    setTunnelNetworkSettings(settings) { [logger] error in
      logger.info("proxy started, error: \(error?.localizedDescription ?? "none", privacy: .public)")
      completionHandler(error)
    }
  }

  override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    logger.info("proxy stopped, reason \(reason.rawValue)")
    reachability.stop()
    completionHandler()
  }

  override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
    guard let flow = flow as? NEAppProxyTCPFlow else { return false }
    // Returning false lets macOS connect the flow directly, so the Mac keeps working without the phone.
    guard reachability.isReachable else { return false }
    // Other network extensions (e.g. Tailscale) manage their own connectivity; tunnelling their
    // control traffic through the phone breaks them, and MagicDNS with them.
    guard !Self.isNetworkExtension(flow.metaData.sourceAppSigningIdentifier) else { return false }
    guard case let .hostPort(endpointHost, endpointPort) = flow.remoteFlowEndpoint else { return false }
    let host = flow.remoteHostname ?? endpointHost.addressString
    let port = endpointPort.rawValue

    DispatchQueue.global().async { [logger] in
      let fd: Int32
      do {
        fd = try TCP.connect(host: "127.0.0.1", port: Self.forwarderPort)
        do {
          try SOCKS5.connect(fd, host: host, port: port)
        } catch {
          close(fd)
          throw error
        }
      } catch {
        logger.error("relay to \(host, privacy: .public):\(port) failed: \(error.localizedDescription, privacy: .public)")
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        return
      }
      logger.info("relaying \(host, privacy: .public):\(port) via iPhone")
      flow.open(withLocalFlowEndpoint: nil) { error in
        if let error {
          close(fd)
          flow.closeReadWithError(error)
          flow.closeWriteWithError(error)
          return
        }
        FlowRelay(flow: flow, fd: fd).start()
      }
    }
    return true
  }

  static func isNetworkExtension(_ signingIdentifier: String) -> Bool {
    let identifier = signingIdentifier.lowercased()
    return identifier.contains("network-extension") || identifier.contains("networkextension")
      || identifier.hasSuffix(".systemextension")
  }
}
