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
  private var sockets: [Destination: RelaySocket] = [:]
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
    guard let socket = lock.withLock({ socket(for: Destination(address: address, port: port)) }) else { return true }
    // `RelaySocket` keeps the descriptor from being closed, and its number reused, mid-send. The send
    // runs outside the lock, and `close()` shuts the socket down, which ends a send stuck on a full buffer.
    _ = socket.write { fd in payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) } >= 0 }
    return true
  }

  /// Stops every socket. Each one closes once its reader wakes up.
  public func close() {
    lock.withLock {
      closed = true
      sockets.values.forEach { $0.close() }
      sockets.removeAll()
    }
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
  /// receive replies. Called with the lock held.
  private func socket(for destination: Destination) -> RelaySocket? {
    if closed { return nil }
    if let socket = sockets[destination] { return socket }
    guard let fd = Self.connectedSocket(to: destination) else { return nil }
    let socket = RelaySocket(fd: fd)
    sockets[destination] = socket
    Thread.detachNewThread { [self] in receive(socket, from: destination) }
    return socket
  }

  /// Reads replies until the socket closes; the thread is the socket's reader.
  private func receive(_ socket: RelaySocket, from destination: Destination) {
    var buffer = [UInt8](repeating: 0, count: 65535)
    while true {
      let received = recv(socket.fd, &buffer, buffer.count, 0)
      if received > 0 {
        onReceive(Data(buffer[0..<received]), destination.address, destination.port)
      } else if received < 0, errno == EINTR || errno == ECONNREFUSED {
        continue
      } else {
        break
      }
    }
    lock.withLock {
      if sockets[destination] === socket { sockets[destination] = nil }
    }
    socket.close()
    socket.readerDidExit()
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
    // A send racing `close()` fails with EPIPE; drop that datagram instead of raising SIGPIPE.
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
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
