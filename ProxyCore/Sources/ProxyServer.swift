import Foundation
import Network
import os

/// A SOCKS5 (CONNECT-only, no-auth) server. Every accepted CONNECT is served by a brand-new
/// outbound connection opened from this device's own network stack.
public final class ProxyServer {
    public struct Configuration {
        public var port: NWEndpoint.Port
        /// Pin outbound connections to an interface type (e.g. `.cellular`). `nil` = system default.
        public var requiredInterfaceType: NWInterface.InterfaceType?
        public var isClientAllowed: (NWEndpoint) -> Bool

        public init(
            port: NWEndpoint.Port = 1080,
            requiredInterfaceType: NWInterface.InterfaceType? = .cellular,
            isClientAllowed: @escaping (NWEndpoint) -> Bool = ProxyServer.isHotspotOrLoopbackClient
        ) {
            self.port = port
            self.requiredInterfaceType = requiredInterfaceType
            self.isClientAllowed = isClientAllowed
        }
    }

    public struct Stats: Codable, Equatable {
        public var activeConnections = 0
        public var totalConnections = 0
        public var bytesUp: UInt64 = 0
        public var bytesDown: UInt64 = 0

        public init() {}
    }

    public enum StartError: Error {
        case listenerFailed(NWError)
        case cancelled
    }

    let configuration: Configuration
    let queue = DispatchQueue(label: "com.suyeol.nothering.proxy")
    let logger = Logger(subsystem: "com.suyeol.nothering", category: "proxy")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var stats = Stats()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Starts listening and returns the bound port once the listener is ready.
    @discardableResult
    public func start() async throws -> NWEndpoint.Port {
        let listener = try NWListener(using: .tcp, on: configuration.port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    self?.logger.info("listening on \(listener.port?.debugDescription ?? "?", privacy: .public)")
                    continuation.resume(returning: listener.port ?? self?.configuration.port ?? 0)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: StartError.listenerFailed(error))
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: StartError.cancelled)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for session in sessions.values {
                session.close()
            }
            sessions.removeAll()
        }
    }

    public func currentStats() -> Stats {
        queue.sync { stats }
    }

    private func accept(_ connection: NWConnection) {
        guard configuration.isClientAllowed(connection.endpoint) else {
            logger.notice("rejected client \(connection.endpoint.debugDescription, privacy: .public)")
            connection.cancel()
            return
        }
        let session = Session(client: connection, server: self)
        sessions[ObjectIdentifier(session)] = session
        stats.activeConnections += 1
        stats.totalConnections += 1
        session.start()
    }

    // MARK: Session callbacks (always on `queue`)

    func sessionDidClose(_ session: Session) {
        if sessions.removeValue(forKey: ObjectIdentifier(session)) != nil {
            stats.activeConnections -= 1
        }
    }

    func record(bytes: Int, upstream: Bool) {
        if upstream {
            stats.bytesUp += UInt64(bytes)
        } else {
            stats.bytesDown += UInt64(bytes)
        }
    }

    // MARK: Client allowlist

    /// Allows loopback and iPhone Personal Hotspot clients (172.20.10.0/28) only, so the proxy
    /// is never reachable from an arbitrary Wi-Fi network the phone happens to be on.
    public static func isHotspotOrLoopbackClient(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            let bytes = [UInt8](address.rawValue)
            return bytes[0] == 127 || (bytes[0] == 172 && bytes[1] == 20 && bytes[2] == 10 && bytes[3] < 16)
        case let .ipv6(address):
            return address == .loopback
        default:
            return false
        }
    }
}

// MARK: - Session

final class Session {
    private let client: NWConnection
    private var upstream: NWConnection?
    private unowned let server: ProxyServer
    private var replied = false
    private var finishedDirections = 0
    private var closed = false

    init(client: NWConnection, server: ProxyServer) {
        self.client = client
        self.server = server
    }

    func start() {
        client.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: close()
            default: break
            }
        }
        client.start(queue: server.queue)
        readGreeting()
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        server.sessionDidClose(self)
    }

    // MARK: Handshake

    private func readGreeting() {
        read(2) { [self] header in
            guard header[0] == 0x05 else { return close() }
            read(Int(header[1])) { [self] methods in
                guard methods.contains(0x00) else {
                    client.send(content: Data([0x05, 0xFF]), completion: .contentProcessed { [self] _ in close() })
                    return
                }
                client.send(content: Data([0x05, 0x00]), completion: .contentProcessed { [self] error in
                    error == nil ? readRequest() : close()
                })
            }
        }
    }

    private func readRequest() {
        read(4) { [self] header in
            guard header[0] == 0x05 else { return close() }
            guard header[1] == 0x01 else { return reply(0x07) } // command not supported
            switch header[3] {
            case 0x01:
                read(6) { [self] body in
                    connect(host: .ipv4(IPv4Address(body.prefix(4))!), portBytes: body.suffix(2))
                }
            case 0x04:
                read(18) { [self] body in
                    connect(host: .ipv6(IPv6Address(body.prefix(16))!), portBytes: body.suffix(2))
                }
            case 0x03:
                read(1) { [self] length in
                    read(Int(length[0]) + 2) { [self] body in
                        guard let name = String(data: body.prefix(body.count - 2), encoding: .utf8) else {
                            return reply(0x01)
                        }
                        connect(host: .name(name, nil), portBytes: body.suffix(2))
                    }
                }
            default:
                reply(0x08) // address type not supported
            }
        }
    }

    private func connect(host: NWEndpoint.Host, portBytes: Data) {
        let bytes = [UInt8](portBytes)
        let port = NWEndpoint.Port(rawValue: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))!
        let parameters = NWParameters.tcp
        if let interfaceType = server.configuration.requiredInterfaceType {
            parameters.requiredInterfaceType = interfaceType
        }
        let upstream = NWConnection(host: host, port: port, using: parameters)
        self.upstream = upstream
        upstream.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                reply(0x00)
            case let .waiting(error), let .failed(error):
                server.logger.notice("connect \(host.debugDescription, privacy: .public):\(port.rawValue) failed: \(error.debugDescription, privacy: .public)")
                replied ? close() : reply(Self.replyCode(for: error))
            case .cancelled:
                close()
            default:
                break
            }
        }
        upstream.start(queue: server.queue)
    }

    /// Sends a SOCKS5 reply. Success starts the relay; any failure closes the session afterwards.
    private func reply(_ code: UInt8) {
        guard !replied else { return }
        replied = true
        let message = Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        client.send(content: message, completion: .contentProcessed { [self] error in
            guard code == 0x00, error == nil, let upstream else { return close() }
            pump(from: client, to: upstream, isUpstream: true)
            pump(from: upstream, to: client, isUpstream: false)
        })
    }

    static func replyCode(for error: NWError) -> UInt8 {
        switch error {
        case .posix(.ECONNREFUSED): return 0x05
        case .posix(.ENETUNREACH), .posix(.ENETDOWN): return 0x03
        case .posix(.EHOSTUNREACH), .posix(.EHOSTDOWN), .dns: return 0x04
        case .posix(.ETIMEDOUT): return 0x06
        default: return 0x01
        }
    }

    // MARK: Relay

    private func pump(from source: NWConnection, to destination: NWConnection, isUpstream: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            guard !closed else { return }
            if let data, !data.isEmpty {
                server.record(bytes: data.count, upstream: isUpstream)
                destination.send(content: data, completion: .contentProcessed { [self] sendError in
                    guard sendError == nil else { return close() }
                    isComplete ? finish(destination) : pump(from: source, to: destination, isUpstream: isUpstream)
                })
            } else if isComplete {
                finish(destination)
            } else if error != nil {
                close()
            }
        }
    }

    /// Propagates EOF (half-close) and tears down once both directions are done.
    private func finish(_ destination: NWConnection) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        finishedDirections += 1
        if finishedDirections == 2 { close() }
    }

    private func read(_ count: Int, _ completion: @escaping (Data) -> Void) {
        guard count > 0 else { return completion(Data()) }
        client.receive(minimumIncompleteLength: count, maximumLength: count) { [self] data, _, _, error in
            guard !closed else { return }
            guard error == nil, let data, data.count == count else { return close() }
            completion(Data(data))
        }
    }
}
