import Darwin
import Foundation
import Network
import NetworkExtension
import os
import PhoneLink

/// Answers DNS queries captured by the DNS proxy. Public names are resolved over TCP through the
/// phone (tethered DNS is what carriers block first); tailnet names, and everything while the phone
/// is unreachable, go to the query's original server as usual.
enum DNSRelay {
  private static let resolver = "1.1.1.1"

  static func handle(_ flow: NEAppProxyUDPFlow, forwarderPort: UInt16, reachability: PhoneReachability, logger: Logger) {
    flow.open(withLocalFlowEndpoint: nil) { error in
      if let error {
        logger.error("DNS flow open failed: \(error.localizedDescription, privacy: .public)")
        return
      }
      readQueries(flow, forwarderPort: forwarderPort, reachability: reachability, logger: logger)
    }
  }

  private static func readQueries(
    _ flow: NEAppProxyUDPFlow, forwarderPort: UInt16, reachability: PhoneReachability, logger: Logger
  ) {
    flow.readDatagrams { datagrams, error in
      guard error == nil, let datagrams, !datagrams.isEmpty else {
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        return
      }
      for (query, server) in datagrams {
        DispatchQueue.global().async {
          let viaPhone = reachability.isReachable && !DNS.isTailscaleName(DNS.queryName(query) ?? "")
          guard let response = resolve(query, server: server, viaPhone: viaPhone, forwarderPort: forwarderPort, logger: logger)
          else { return }
          flow.writeDatagrams([(response, server)]) { _ in }
        }
      }
      readQueries(flow, forwarderPort: forwarderPort, reachability: reachability, logger: logger)
    }
  }

  private static func resolve(
    _ query: Data, server: Network.NWEndpoint, viaPhone: Bool, forwarderPort: UInt16, logger: Logger
  ) -> Data? {
    do {
      if viaPhone {
        let fd = try TCP.connect(host: "127.0.0.1", port: forwarderPort)
        defer { close(fd) }
        setReceiveTimeout(fd, seconds: 5)
        try SOCKS5.connect(fd, host: resolver, port: 53)
        return try DNS.exchangeOverTCP(fd, query: query)
      }
      guard case let .hostPort(host, port) = server else { return nil }
      return try exchangeOverUDP(query, host: host.addressString, port: port.rawValue)
    } catch {
      logger.error("DNS \(DNS.queryName(query) ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  private static func exchangeOverUDP(_ query: Data, host: String, port: UInt16) throws -> Data {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_DGRAM
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
      throw LinkError("DNS server address \(host) is invalid")
    }
    defer { freeaddrinfo(result) }
    let fd = socket(info.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { throw LinkError("DNS socket: \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    setReceiveTimeout(fd, seconds: 3)
    // A connected socket keeps the reply "outbound" for the sandbox; recv on an unconnected one is denied.
    guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
      throw LinkError("DNS connect: \(String(cString: strerror(errno)))")
    }
    let sent = query.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    guard sent == query.count else { throw LinkError("DNS send: \(String(cString: strerror(errno)))") }
    var response = [UInt8](repeating: 0, count: 65535)
    let received = recv(fd, &response, response.count, 0)
    guard received > 0 else { throw LinkError("DNS receive: \(String(cString: strerror(errno)))") }
    return Data(response[0..<received])
  }

  private static func setReceiveTimeout(_ fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }
}

extension Network.NWEndpoint.Host {
  /// The host as a string usable with getaddrinfo, keeping any IPv6 scope (e.g. `fe80::1%en0`).
  var addressString: String {
    switch self {
    case let .name(name, _): name
    case let .ipv4(address): "\(address)"
    case let .ipv6(address): "\(address)"
    @unknown default: "\(self)"
    }
  }
}
