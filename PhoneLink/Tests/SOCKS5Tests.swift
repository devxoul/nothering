import Darwin
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
