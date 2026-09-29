import Darwin
import Foundation
import Network
import NetworkExtension
import os
import PhoneLink

/// Answers captured DNS queries: tailnet names go to Tailscale's MagicDNS as before; everything
/// else is resolved over TCP through the phone, since tethered DNS is what carriers block first.
enum DNSRelay {
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
