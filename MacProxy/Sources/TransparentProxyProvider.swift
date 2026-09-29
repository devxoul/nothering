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

  /// Destinations that must never go through the phone: loopback-like, LAN, link-local (the hotspot
  /// link itself), 464XLAT, CGNAT/Tailscale and unique-local ranges.
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
        localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound
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
