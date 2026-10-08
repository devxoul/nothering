import Darwin
import Foundation
import Network
import PhoneLink
import ProxyCore
import Testing

@Suite struct SOCKS5Tests {
  @Test func connectsThroughProxyServer() async throws {
    let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil))
    let port = try await server.start().rawValue
    defer { server.stop() }

    let fd = try TCP.connect(host: "127.0.0.1", port: port)
    defer { close(fd) }
    try SOCKS5.connect(fd, host: "127.0.0.1", port: port)
  }

  @Test func exchangesDatagramFramesThroughProxyServer() async throws {
    let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil))
    let port = try await server.start().rawValue
    defer { server.stop() }
    let echo = try UDPEcho()
    defer { echo.stop() }

    let fd = try TCP.connect(host: "127.0.0.1", port: port)
    defer { close(fd) }
    try SOCKS5.openDatagramSession(fd)
    let destination = NWEndpoint.Port(rawValue: echo.port)!
    try SOCKS5.writeFrame(fd, DatagramFrame.encode(Data("hi".utf8), host: .ipv4(.loopback), port: destination)!)
    let reply = try #require(DatagramFrame.decode(body: SOCKS5.readFrame(fd)))
    #expect(reply.host == .ipv4(.loopback))
    #expect(reply.port == destination)
    #expect(reply.payload == Data("hi".utf8))
  }

  @Test func readsEventsFromProxyServer() async throws {
    let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil))
    let port = try await server.start().rawValue
    defer { server.stop() }

    let fd = try TCP.connect(host: "127.0.0.1", port: port)
    defer { close(fd) }
    try SOCKS5.openEventStream(fd)
    server.send(.terminating)
    #expect(try SOCKS5.readEvent(fd) == ProxyEvent.terminating.rawValue)
  }

  @Test func reportsRefusedDestination() async throws {
    let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil))
    let port = try await server.start().rawValue
    defer { server.stop() }

    let fd = try TCP.connect(host: "127.0.0.1", port: port)
    defer { close(fd) }
    #expect(throws: LinkError.self) { try SOCKS5.connect(fd, host: "127.0.0.1", port: 1) }
  }
}

@Test func greetFailsWhenNothingAnswers() throws {
  var fds: [Int32] = [0, 0]
  #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
  var on: Int32 = 1
  setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  close(fds[1])
  defer { close(fds[0]) }
  #expect(throws: LinkError.self) { try SOCKS5.greet(fds[0]) }
}

/// Echoes one datagram at a time on 127.0.0.1 from a background thread.
private final class UDPEcho: @unchecked Sendable {
  let port: UInt16
  private let fd: Int32

  init() throws {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    self.fd = fd
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
      }
    }
    guard bound else { throw LinkError("UDP echo bind failed") }
    port = UInt16(bigEndian: address.sin_port)
    Thread.detachNewThread { [fd] in
      var buffer = [UInt8](repeating: 0, count: 2048)
      var peer = sockaddr_storage()
      var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
      while true {
        let count = withUnsafeMutablePointer(to: &peer) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &peerLength) }
        }
        guard count > 0 else { return }
        _ = withUnsafePointer(to: &peer) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer, count, 0, $0, peerLength) }
        }
      }
    }
  }

  func stop() {
    shutdown(fd, SHUT_RDWR)
    close(fd)
  }
}
