import Darwin
import Foundation
import PhoneLink
import Testing

/// A UDP socket on 127.0.0.1 that sends every datagram back to its sender.
private final class EchoServer {
  let fd: Int32
  let port: UInt16

  init() throws {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
    }
    guard bound else {
      close(fd)
      throw POSIXError(.EADDRNOTAVAIL)
    }
    self.fd = fd
    port = UInt16(bigEndian: address.sin_port)
    Thread.detachNewThread {
      var buffer = [UInt8](repeating: 0, count: 2048)
      var sender = sockaddr_storage()
      var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
      while true {
        let received = withUnsafeMutablePointer(to: &sender) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength) }
        }
        guard received > 0 else { return }
        _ = withUnsafePointer(to: &sender) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer, received, 0, $0, senderLength) }
        }
      }
    }
  }

  deinit {
    shutdown(fd, SHUT_RDWR)
    close(fd)
  }
}

@Suite struct TunnelDatagramsTests {
  private let loopback = Data([127, 0, 0, 1])

  @Test func sendsOnlyRoutedDestinationsStraightAndRelaysTheirReplies() throws {
    let echo = try EchoServer()
    let replied = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var replies: [(Data, Data, UInt16)] = []
    let tunnel = TunnelDatagrams(routes: { $0 == loopback }) { payload, address, port in
      lock.lock()
      replies.append((payload, address, port))
      lock.unlock()
      replied.signal()
    }
    defer { tunnel.close() }

    // A flow that starts at a public address and later reaches a routed one.
    #expect(!tunnel.sendIfRouted(Data("stun".utf8), to: Data([203, 0, 113, 1]), port: 3478))
    #expect(tunnel.sendIfRouted(Data("hello".utf8), to: loopback, port: echo.port))

    #expect(replied.wait(timeout: .now() + 5) == .success)
    lock.lock()
    defer { lock.unlock() }
    #expect(replies.count == 1)
    #expect(replies.first?.0 == Data("hello".utf8))
    #expect(replies.first?.1 == loopback)
    #expect(replies.first?.2 == echo.port)
  }
}
