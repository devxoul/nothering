import Foundation
import Network
import Testing
@testable import ProxyCore

private let loopback = NWEndpoint.Host.ipv4(.loopback)

@Suite struct ProxyServerTests {
  @Test func relaysThroughIPv4Connect() async throws {
    let (echo, echoPort) = try await startEchoServer()
    defer { echo.cancel() }
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1]) + portBytes(echoPort))
    #expect(try await client.receiveExactly(10)[1] == 0x00)

    try await client.sendAsync(Data("hello".utf8))
    #expect(try await client.receiveExactly(5) == Data("hello".utf8))
    client.cancel()

    let stats = server.currentStats()
    #expect(stats.totalConnections == 1)
    #expect(stats.bytesUp == 5)
    #expect(stats.bytesDown == 5)
  }

  @Test func relaysThroughDomainConnect() async throws {
    let (echo, echoPort) = try await startEchoServer()
    defer { echo.cancel() }
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    let name = Data("localhost".utf8)
    try await client.sendAsync(Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)]) + name + portBytes(echoPort))
    #expect(try await client.receiveExactly(10)[1] == 0x00)

    try await client.sendAsync(Data("ping".utf8))
    #expect(try await client.receiveExactly(4) == Data("ping".utf8))
    client.cancel()
  }

  @Test func rejectsUnsupportedCommand() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0, 80]))
    #expect(try await client.receiveExactly(10)[1] == 0x07)
    client.cancel()
  }

  @Test func reportsRefusedConnection() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0, 1]))
    #expect(try await client.receiveExactly(10)[1] == 0x05)
    client.cancel()
  }

  @Test(arguments: [
    ("127.0.0.1", true),
    ("172.20.10.2", true),
    ("172.20.10.15", true),
    ("172.20.10.16", false),
    ("192.168.0.10", false),
    ("::1", true),
    ("fe80::1", false),
  ])
  func allowsOnlyHotspotOrLoopbackClients(address: String, allowed: Bool) {
    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(address), port: 50000)
    #expect(ProxyServer.isHotspotOrLoopbackClient(endpoint) == allowed)
  }
}

// MARK: - Helpers

private func startProxy() async throws -> (ProxyServer, NWEndpoint.Port) {
  let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil))
  let port = try await server.start()
  return (server, port)
}

private func portBytes(_ port: NWEndpoint.Port) -> Data {
  Data([UInt8(port.rawValue >> 8), UInt8(port.rawValue & 0xFF)])
}

private func socksHandshake(proxyPort: NWEndpoint.Port) async throws -> NWConnection {
  let client = NWConnection(host: loopback, port: proxyPort, using: .tcp)
  try await client.startAndWaitReady()
  try await client.sendAsync(Data([0x05, 0x01, 0x00]))
  #expect(try await client.receiveExactly(2) == Data([0x05, 0x00]))
  return client
}

private func startEchoServer() async throws -> (NWListener, NWEndpoint.Port) {
  let listener = try NWListener(using: .tcp, on: .any)
  let queue = DispatchQueue(label: "echo")
  listener.newConnectionHandler = { connection in
    connection.start(queue: queue)
    func echo() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
        if let data, !data.isEmpty {
          connection.send(content: data, completion: .contentProcessed { _ in echo() })
        } else if isComplete || error != nil {
          connection.cancel()
        }
      }
    }
    echo()
  }
  let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        listener.stateUpdateHandler = nil
        continuation.resume(returning: listener.port!)
      case let .failed(error):
        listener.stateUpdateHandler = nil
        continuation.resume(throwing: error)
      default:
        break
      }
    }
    listener.start(queue: queue)
  }
  return (listener, port)
}

private extension NWConnection {
  func startAndWaitReady() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          self?.stateUpdateHandler = nil
          continuation.resume()
        case let .failed(error), let .waiting(error):
          self?.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default:
          break
        }
      }
      start(queue: DispatchQueue(label: "client"))
    }
  }

  func sendAsync(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      send(content: data, completion: .contentProcessed { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      })
    }
  }

  func receiveExactly(_ count: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: data ?? Data())
        }
      }
    }
  }
}
