import Darwin
import Foundation

/// Dual-stack TCP listener on a plain BSD socket.
///
/// `NWListener` only opens flows on interfaces its path evaluator picks (Wi-Fi / cellular), so
/// clients on the Personal Hotspot bridge never reach it. A kernel socket bound to `::` accepts
/// on every interface, like iOS's own lockdownd does.
final class SocketListener {
  let port: UInt16
  private let fd: Int32
  private let source: DispatchSourceRead

  /// `onAccept` receives the connected socket and the name of the local interface it arrived on.
  init(port: UInt16, queue: DispatchQueue, onAccept: @escaping (Int32, String?) -> Void) throws {
    let fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw SocketError("socket") }

    do {
      var off: Int32 = 0
      var on: Int32 = 1
      let size = socklen_t(MemoryLayout<Int32>.size)
      setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, size)
      setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
      // SO_RECV_ANYIF (private, <sys/socket.h>): without it the kernel drops inbound SYNs arriving on
      // restricted-receive interfaces such as the Personal Hotspot link.
      setsockopt(fd, SOL_SOCKET, 0x1104, &on, size)

      var address = sockaddr_in6()
      address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_port = port.bigEndian
      address.sin6_addr = in6addr_any
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
      }
      guard bound == 0 else { throw SocketError("bind") }
      guard listen(fd, 128) == 0 else { throw SocketError("listen") }
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
      self.port = try Self.localPort(of: fd)
    } catch {
      Darwin.close(fd)
      throw error
    }

    self.fd = fd
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler {
      while true {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        onAccept(client, Self.interfaceName(ofLocalAddressOf: client))
      }
    }
    source.setCancelHandler { Darwin.close(fd) }
    source.resume()
  }

  func cancel() {
    source.cancel()
  }

  private static func localPort(of fd: Int32) throws -> UInt16 {
    var address = sockaddr_in6()
    var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
    let result = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard result == 0 else { throw SocketError("getsockname") }
    return UInt16(bigEndian: address.sin6_port)
  }

  /// Resolves which interface owns the address a client connected to.
  static func interfaceName(ofLocalAddressOf fd: Int32) -> String? {
    var local = sockaddr_in6()
    var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
    let result = withUnsafeMutablePointer(to: &local) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard result == 0 else { return nil }

    if local.sin6_scope_id != 0 {
      var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
      return if_indextoname(local.sin6_scope_id, &name).map { String(cString: $0) }
    }

    let localBytes = withUnsafeBytes(of: local.sin6_addr) { [UInt8]($0) }
    let isV4Mapped = localBytes[0..<10].allSatisfy { $0 == 0 } && localBytes[10] == 0xFF && localBytes[11] == 0xFF

    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
    defer { freeifaddrs(interfaces) }

    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
      guard let address = entry.pointee.ifa_addr else { continue }
      let matches: Bool
      switch Int32(address.pointee.sa_family) {
      case AF_INET6 where !isV4Mapped:
        matches = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
          withUnsafeBytes(of: $0.pointee.sin6_addr) { [UInt8]($0) } == localBytes
        }
      case AF_INET where isV4Mapped:
        matches = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          withUnsafeBytes(of: $0.pointee.sin_addr) { [UInt8]($0) } == Array(localBytes[12...])
        }
      default:
        matches = false
      }
      if matches { return String(cString: entry.pointee.ifa_name) }
    }
    return nil
  }
}
