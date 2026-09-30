import Darwin
import Network
import NetworkExtension
import os
import PhoneLink

/// Receives app TCP and UDP flows from macOS and relays each one to the iPhone's SOCKS5 proxy.
final class TransparentProxyProvider: NETransparentProxyProvider {
  private let logger = Logger(subsystem: "app.nothering", category: "proxy")
  /// The menu bar app's forwarder, which owns the USB / hotspot link to the phone.
  private static let forwarderPort: UInt16 = 11080

  /// Destinations that must never go through the phone: LAN, link-local (the hotspot link itself),
  /// 464XLAT, CGNAT/Tailscale, unique-local, multicast and broadcast ranges.
  private static let excludedNetworks: [(String, Int)] = [
    ("10.0.0.0", 8), ("172.16.0.0", 12), ("192.168.0.0", 16), ("169.254.0.0", 16),
    ("100.64.0.0", 10), ("192.0.0.0", 24), ("fe80::", 10), ("fc00::", 7),
    ("224.0.0.0", 4), ("255.255.255.255", 32), ("ff00::", 8),
  ]

  private let reachability = PhoneReachability(forwarderPort: forwarderPort)

  override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
    let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let protocols: [NENetworkRule.`Protocol`] = [.TCP, .UDP]
    settings.includedNetworkRules = protocols.map { proto in
      NENetworkRule(
        remoteNetworkEndpoint: nil, remotePrefix: 0,
        localNetworkEndpoint: nil, localPrefix: 0, protocol: proto, direction: .outbound
      )
    }
    settings.excludedNetworkRules = protocols.flatMap { proto in
      Self.excludedNetworks.map { address, prefix in
        NENetworkRule(
          remoteNetworkEndpoint: .hostPort(host: Network.NWEndpoint.Host(address), port: 0), remotePrefix: prefix,
          localNetworkEndpoint: nil, localPrefix: 0, protocol: proto, direction: .outbound
        )
      }
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
    // Returning false lets macOS connect the flow directly, so the Mac keeps working without the phone.
    guard reachability.isReachable else { return false }
    // Other network extensions (VPNs) manage their own connectivity and are left alone. Tailscale's
    // TCP (control plane and DERP relays) is the exception: when the carrier blocks its direct
    // WireGuard UDP, DERP over the phone is what keeps the tailnet, and MagicDNS, working.
    let source = flow.metaData.sourceAppSigningIdentifier
    if let flow = flow as? NEAppProxyUDPFlow {
      // An older phone app can't relay UDP; send it direct rather than failing it.
      guard reachability.supportsDatagrams, !Self.isNetworkExtension(source) else { return false }
      relayDatagrams(flow)
      return true
    }
    guard let flow = flow as? NEAppProxyTCPFlow else { return false }
    guard !Self.isNetworkExtension(source) || Self.isTailscale(source) else { return false }
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

  private func relayDatagrams(_ flow: NEAppProxyUDPFlow) {
    DispatchQueue.global().async { [logger] in
      let fd: Int32
      do {
        fd = try TCP.connect(host: "127.0.0.1", port: Self.forwarderPort)
        do {
          try SOCKS5.openDatagramSession(fd)
        } catch {
          close(fd)
          throw error
        }
      } catch {
        logger.error("UDP relay for \(flow.metaData.sourceAppSigningIdentifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        return
      }
      flow.open(withLocalFlowEndpoint: nil) { error in
        if let error {
          close(fd)
          flow.closeReadWithError(error)
          flow.closeWriteWithError(error)
          return
        }
        DatagramFlowRelay(flow: flow, fd: fd).start()
      }
    }
  }

  static func isNetworkExtension(_ signingIdentifier: String) -> Bool {
    let identifier = signingIdentifier.lowercased()
    return identifier.contains("network-extension") || identifier.contains("networkextension")
      || identifier.hasSuffix(".systemextension")
  }

  /// Tailscale's network extension, standalone (`io.tailscale.ipn.macsys…`) or App Store build.
  static func isTailscale(_ signingIdentifier: String) -> Bool {
    signingIdentifier.lowercased().hasPrefix("io.tailscale.ipn.")
  }
}
