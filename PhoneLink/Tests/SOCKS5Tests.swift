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
