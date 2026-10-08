import Darwin
import Foundation

/// Blocking SOCKS5 (no-auth) client over an already-connected socket: CONNECT, plus Nothering's
/// framed UDP extension (ProxyCore's `DatagramFrame`).
public enum SOCKS5 {
  /// Nothering's framed-UDP command, `DatagramFrame.command` on the server side.
  private static let datagramCommand: UInt8 = 0x83
  /// Nothering's event-stream command, `ProxyEvent.command` on the server side.
  private static let eventCommand: UInt8 = 0x84

  /// Asks the proxy on the other end of `fd` to connect to `host:port`. `host` is sent as a
  /// domain name so the phone resolves it; IP literals work the same way.
  public static func connect(_ fd: Int32, host: String, port: UInt16) throws {
    let name = Array(host.utf8)
    guard !name.isEmpty, name.count <= 255 else { throw LinkError("invalid SOCKS5 host \(host)") }
    try greet(fd)
    try request(fd, command: 0x01, address: [0x03, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xFF)])
  }

  /// Turns `fd` into a framed-UDP session; afterwards exchange frames with `readFrame` / `writeFrame`.
  public static func openDatagramSession(_ fd: Int32) throws {
    try greet(fd)
    try requestDatagramSession(fd)
  }

  /// Like `openDatagramSession`, on a socket that has already completed `greet`. Throws when the
  /// proxy predates framed UDP.
  public static func requestDatagramSession(_ fd: Int32) throws {
    try request(fd, command: datagramCommand, address: [0x01, 0, 0, 0, 0, 0, 0])
  }

  /// Turns `fd` into an event stream; afterwards read events with `readEvent`. Throws when the
  /// proxy predates events.
  public static func openEventStream(_ fd: Int32) throws {
    try greet(fd)
    try request(fd, command: eventCommand, address: [0x01, 0, 0, 0, 0, 0, 0])
  }

  /// Blocks until the next event byte (ProxyCore's `ProxyEvent`) arrives.
  public static func readEvent(_ fd: Int32) throws -> UInt8 {
    try readExactly(fd, 1)[0]
  }

  /// Reads one datagram frame and returns it without its length prefix.
  public static func readFrame(_ fd: Int32) throws -> Data {
    let header = try readExactly(fd, 2)
    return Data(try readExactly(fd, Int(header[0]) << 8 | Int(header[1])))
  }

  /// Writes one already-encoded datagram frame, length prefix included.
  public static func writeFrame(_ fd: Int32, _ frame: Data) throws {
    try writeAll(fd, [UInt8](frame))
  }

  private static func request(_ fd: Int32, command: UInt8, address: [UInt8]) throws {
    try writeAll(fd, [0x05, command, 0x00] + address)
    let reply = try readExactly(fd, 4)
    guard reply[1] == 0x00 else { throw LinkError("SOCKS5 command \(command) failed (code \(reply[1]))") }
    switch reply[3] {
    case 0x01: _ = try readExactly(fd, 6)
    case 0x04: _ = try readExactly(fd, 18)
    case 0x03: _ = try readExactly(fd, Int(try readExactly(fd, 1)[0]) + 2)
    default: throw LinkError("SOCKS5 reply has unknown address type")
    }
  }

  /// Performs only the method negotiation; succeeds when a SOCKS5 proxy is answering on `fd`.
  public static func greet(_ fd: Int32) throws {
    try writeAll(fd, [0x05, 0x01, 0x00])
    guard try readExactly(fd, 2) == [0x05, 0x00] else { throw LinkError("SOCKS5 proxy refused no-auth") }
  }

  private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
      guard written > 0 else { throw LinkError("SOCKS5 write: \(String(cString: strerror(errno)))") }
      offset += written
    }
  }

  private static func readExactly(_ fd: Int32, _ count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      let received = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
      guard received > 0 else { throw LinkError("SOCKS5 proxy closed the connection") }
      offset += received
    }
    return bytes
  }
}
