import Darwin
import Network
import NetworkExtension
import os
import PhoneLink

/// Receives app TCP and UDP flows from macOS and relays each one to the iPhone's SOCKS5 proxy.
final class TransparentProxyProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling {
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
  private let relaysLock = NSLock()
  private var sessionRelays = LiveRelays()
  private var relays: LiveRelays { relaysLock.withLock { sessionRelays } }

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
    // A fresh registry per session, so a setup left over from the previous one can't join this one.
    relaysLock.withLock { sessionRelays = LiveRelays() }
    reachability.start()
    setTunnelNetworkSettings(settings) { [logger] error in
      logger.info("proxy started, error: \(error?.localizedDescription ?? "none", privacy: .public)")
      completionHandler(error)
    }
  }

  override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    logger.info("proxy stopped, reason \(reason.rawValue)")
    reachability.stop()
    relays.closeAll()
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
    guard !Self.isNetworkExtension(source) || Tailscale.isTailscaleApp(source) else { return false }
    guard case let .hostPort(endpointHost, endpointPort) = flow.remoteFlowEndpoint else { return false }
    // Subnet routes, app connectors and exit nodes only work through the tunnel.
    if let address = endpointHost.addressData, Tailscale.staysOnTunnel(address, from: source) { return false }
    // The phone resolves a name again, with public DNS that knows nothing of the Mac's own overrides
    // (/etc/hosts, per-domain resolvers). Send the name only when the phone's DNS gave the address
    // the app connected to; otherwise send that address.
    let host: String
    if let name = flow.remoteHostname, let address = endpointHost.addressData,
       ResolvedNames.phone.contains(address, for: name) {
      host = name
    } else {
      host = endpointHost.addressString
    }
    let port = endpointPort.rawValue

    startRelay(for: flow, label: "relay to \(host):\(port)") { [logger] fd in
      try SOCKS5.connect(fd, host: host, port: port)
      logger.info("relaying \(host, privacy: .public):\(port) via iPhone")
    } makeRelay: { socket, onClose in
      FlowRelay(flow: flow, socket: socket, onClose: onClose)
    }
    return true
  }

  func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool {
    // QUIC to a Tailscale-routed address has to stay on the tunnel just like TCP. Later datagrams to
    // other destinations are checked one by one in `DatagramFlowRelay`.
    if case let .hostPort(host, _) = remoteEndpoint, let address = host.addressData,
       Tailscale.staysOnTunnel(address, from: flow.metaData.sourceAppSigningIdentifier) {
      return false
    }
    return handleNewFlow(flow)
  }

  private func relayDatagrams(_ flow: NEAppProxyUDPFlow) {
    startRelay(for: flow, label: "UDP relay for \(flow.metaData.sourceAppSigningIdentifier)") { fd in
      try SOCKS5.openDatagramSession(fd)
    } makeRelay: { socket, onClose in
      DatagramFlowRelay(flow: flow, socket: socket, onClose: onClose)
    }
  }

  /// Connects to the forwarder, runs `handshake` on that socket, opens the flow and starts the relay
  /// `makeRelay` returns. The socket is tracked from the moment it exists, so stopping the session
  /// also ends a setup still waiting on the forwarder or on the flow to open.
  private func startRelay(
    for flow: NEAppProxyFlow, label: String, handshake: @escaping (Int32) throws -> Void,
    makeRelay: @escaping (RelaySocket, _ onClose: @escaping () -> Void) -> SessionRelay
  ) {
    let relays = relays
    DispatchQueue.global().async { [logger] in
      let id = UUID()
      let fail = { (error: Error) in
        relays.remove(id)
        logger.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
      }
      let socket: RelaySocket
      do {
        socket = RelaySocket(fd: try TCP.connect(host: "127.0.0.1", port: Self.forwarderPort))
      } catch {
        return fail(error)
      }
      do {
        guard relays.insert(id, close: socket.close) else { throw LinkError("proxy stopped") }
        try handshake(socket.fd)
      } catch {
        socket.discard()
        return fail(error)
      }
      flow.open(withLocalFlowEndpoint: nil) { error in
        if let error {
          socket.discard()
          return fail(error)
        }
        let relay = makeRelay(socket) { relays.remove(id) }
        let accepted = relays.insert(id, close: relay.close)
        relay.start()
        if !accepted { relay.close() }
      }
    }
  }

  static func isNetworkExtension(_ signingIdentifier: String) -> Bool {
    let identifier = signingIdentifier.lowercased()
    return identifier.contains("network-extension") || identifier.contains("networkextension")
      || identifier.hasSuffix(".systemextension")
  }

}
