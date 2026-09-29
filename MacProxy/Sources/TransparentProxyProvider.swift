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
    let host = flow.remoteHostname ?? Self.string(for: endpointHost)
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

  private static func string(for host: Network.NWEndpoint.Host) -> String {
    switch host {
    case let .name(name, _): name
    case let .ipv4(address): "\(address)"
    case let .ipv6(address): "\(address)"
    @unknown default: "\(host)"
    }
  }
}

/// Pumps bytes between an app flow and a blocking socket until both directions finish.
private final class FlowRelay {
  private let flow: NEAppProxyTCPFlow
  private let fd: Int32
  private let lock = NSLock()
  private var openDirections = 2

  init(flow: NEAppProxyTCPFlow, fd: Int32) {
    self.flow = flow
    self.fd = fd
  }

  func start() {
    readFromFlow()
    Thread.detachNewThread { [self] in readFromSocket() }
  }

  private func readFromFlow() {
    flow.readData { [self] data, error in
      guard error == nil, let data, !data.isEmpty else {
        shutdown(fd, SHUT_WR)
        return directionDone()
      }
      let written = data.withUnsafeBytes { buffer -> Bool in
        var offset = 0
        while offset < buffer.count {
          let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
          guard count > 0 else { return false }
          offset += count
        }
        return true
      }
      guard written else {
        flow.closeReadWithError(nil)
        return directionDone()
      }
      readFromFlow()
    }
  }

  private func readFromSocket() {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = read(fd, &buffer, buffer.count)
      guard count > 0 else { break }
      let sent = DispatchSemaphore(value: 0)
      var failed = false
      flow.write(Data(buffer[0..<count])) { error in
        failed = error != nil
        sent.signal()
      }
      sent.wait()
      if failed { break }
    }
    flow.closeWriteWithError(nil)
    directionDone()
  }

  private func directionDone() {
    lock.lock()
    openDirections -= 1
    let finished = openDirections == 0
    lock.unlock()
    if finished {
      close(fd)
      flow.closeReadWithError(nil)
    }
  }
}

/// Tracks whether the app's forwarder can currently reach the phone, by periodically completing a
/// SOCKS5 greeting through it (the forwarder only answers once its upstream link is connected).
private final class PhoneReachability {
  private let forwarderPort: UInt16
  private let lock = NSLock()
  private var reachable = false
  private var timer: DispatchSourceTimer?

  init(forwarderPort: UInt16) {
    self.forwarderPort = forwarderPort
  }

  var isReachable: Bool {
    lock.withLock { reachable }
  }

  func start() {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now(), repeating: 3)
    timer.setEventHandler { [weak self] in self?.probe() }
    timer.resume()
    self.timer = timer
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  private func probe() {
    var result = false
    if let fd = try? TCP.connect(host: "127.0.0.1", port: forwarderPort, timeout: 2) {
      var timeout = timeval(tv_sec: 3, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      result = (try? SOCKS5.greet(fd)) != nil
      close(fd)
    }
    lock.withLock { reachable = result }
  }
}

/// Answers captured DNS queries: tailnet names go to Tailscale's MagicDNS as before; everything
/// else is resolved over TCP through the phone, since tethered DNS is what carriers block first.
private enum DNSRelay {
  private static let resolver = "1.1.1.1"
  private static let magicDNS = "100.100.100.100"

  static func handle(_ flow: NEAppProxyUDPFlow, forwarderPort: UInt16, logger: Logger) -> Bool {
    flow.open(withLocalFlowEndpoint: nil) { error in
      if let error {
        logger.error("DNS flow open failed: \(error.localizedDescription, privacy: .public)")
        return
      }
      readQueries(flow, forwarderPort: forwarderPort, logger: logger)
    }
    return true
  }

  private static func readQueries(_ flow: NEAppProxyUDPFlow, forwarderPort: UInt16, logger: Logger) {
    flow.readDatagrams { datagrams, error in
      guard error == nil, let datagrams, !datagrams.isEmpty else {
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        return
      }
      for (query, endpoint) in datagrams {
        DispatchQueue.global().async {
          guard let response = resolve(query, forwarderPort: forwarderPort, logger: logger) else { return }
          flow.writeDatagrams([(response, endpoint)]) { _ in }
        }
      }
      readQueries(flow, forwarderPort: forwarderPort, logger: logger)
    }
  }

  private static func resolve(_ query: Data, forwarderPort: UInt16, logger: Logger) -> Data? {
    let name = DNS.queryName(query) ?? ""
    do {
      if DNS.isTailscaleName(name) {
        return try exchangeOverUDP(query, server: magicDNS)
      }
      let fd = try TCP.connect(host: "127.0.0.1", port: forwarderPort)
      defer { close(fd) }
      var timeout = timeval(tv_sec: 5, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      try SOCKS5.connect(fd, host: resolver, port: 53)
      return try DNS.exchangeOverTCP(fd, query: query)
    } catch {
      logger.error("DNS \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  private static func exchangeOverUDP(_ query: Data, server: String) throws -> Data {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { throw LinkError("DNS socket: \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(53).bigEndian
    address.sin_addr.s_addr = inet_addr(server)
    let sent = query.withUnsafeBytes { buffer in
      withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    guard sent == query.count else { throw LinkError("DNS send: \(String(cString: strerror(errno)))") }
    var response = [UInt8](repeating: 0, count: 65535)
    let received = recv(fd, &response, response.count, 0)
    guard received > 0 else { throw LinkError("DNS receive: \(String(cString: strerror(errno)))") }
    return Data(response[0..<received])
  }
}
