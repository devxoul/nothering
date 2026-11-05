import Darwin
import Foundation

/// The part of one app UDP flow that goes straight to Tailscale-routed destinations instead of through
/// the phone. A UDP flow names a destination per datagram, so a flow that started at a public address
/// can later reach one behind a subnet route or app connector.
public final class TunnelDatagrams: @unchecked Sendable {
  private struct Destination: Hashable {
    let address: Data
    let port: UInt16
  }

  private let routes: (Data) -> Bool
  private let onReceive: (Data, Data, UInt16) -> Void
  private let lock = NSLock()
  private var routed: [Data: Bool] = [:]
  private var sockets: [Destination: Int32] = [:]
  private var closed = false

  /// `onReceive` gets each reply with the raw address and port it came from.
  public init(
    routes: @escaping (Data) -> Bool = Tailscale.routesThroughTailscale,
    onReceive: @escaping (_ payload: Data, _ address: Data, _ port: UInt16) -> Void
  ) {
    self.routes = routes
    self.onReceive = onReceive
  }

  /// Sends the datagram straight to its destination when the Mac routes that address through
  /// Tailscale, and returns whether it took the datagram. A datagram that can't be sent is dropped,
  /// like any lost UDP packet.
  public func sendIfRouted(_ payload: Data, to address: Data, port: UInt16) -> Bool {
    guard isRouted(address) else { return false }
    guard let fd = socket(for: Destination(address: address, port: port)) else { return true }
    _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    return true
  }

  /// Stops every socket. Each one closes once its reader wakes up.
  public func close() {
    lock.lock()
    closed = true
    let open = Array(sockets.values)
    sockets.removeAll()
    lock.unlock()
    open.forEach { shutdown($0, SHUT_RDWR) }
  }

  private func isRouted(_ address: Data) -> Bool {
    lock.lock()
    if let known = routed[address] {
      lock.unlock()
      return known
    }
    lock.unlock()
    let result = routes(address)
    lock.lock()
    routed[address] = result
    lock.unlock()
    return result
  }

  /// One connected socket per destination: the extension's sandbox only lets a connected UDP socket
  /// receive replies.
  private func socket(for destination: Destination) -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    if closed { return nil }
    if let fd = sockets[destination] { return fd }
    guard let fd = Self.connectedSocket(to: destination) else { return nil }
    sockets[destination] = fd
    Thread.detachNewThread { [self] in receive(fd, from: destination) }
    return fd
  }

  private func receive(_ fd: Int32, from destination: Destination) {
    var buffer = [UInt8](repeating: 0, count: 65535)
    while true {
      let received = recv(fd, &buffer, buffer.count, 0)
      if received > 0 {
        onReceive(Data(buffer[0..<received]), destination.address, destination.port)
      } else if received < 0, errno == EINTR || errno == ECONNREFUSED {
        continue
      } else {
        break
      }
    }
    lock.lock()
    if sockets[destination] == fd { sockets[destination] = nil }
    lock.unlock()
    Darwin.close(fd)
  }

  private static func connectedSocket(to destination: Destination) -> Int32? {
    var storage = sockaddr_storage()
    let length: socklen_t
    switch destination.address.count {
    case 4:
      length = socklen_t(MemoryLayout<sockaddr_in>.size)
      withUnsafeMutableBytes(of: &storage) { raw in
        let sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
        sin.pointee.sin_len = UInt8(length)
        sin.pointee.sin_family = sa_family_t(AF_INET)
        sin.pointee.sin_port = destination.port.bigEndian
        _ = destination.address.withUnsafeBytes { memcpy(&sin.pointee.sin_addr, $0.baseAddress!, 4) }
      }
    case 16:
      length = socklen_t(MemoryLayout<sockaddr_in6>.size)
      withUnsafeMutableBytes(of: &storage) { raw in
        let sin6 = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self)
        sin6.pointee.sin6_len = UInt8(length)
        sin6.pointee.sin6_family = sa_family_t(AF_INET6)
        sin6.pointee.sin6_port = destination.port.bigEndian
        _ = destination.address.withUnsafeBytes { memcpy(&sin6.pointee.sin6_addr, $0.baseAddress!, 16) }
      }
    default:
      return nil
    }
    let fd = Darwin.socket(Int32(storage.ss_family), SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return nil }
    let connected = withUnsafePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
    }
    guard connected == 0 else {
      Darwin.close(fd)
      return nil
    }
    return fd
  }
}
