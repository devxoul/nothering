import Darwin
import Foundation

/// Blocking SOCKS5 (no-auth, CONNECT) client handshake over an already-connected socket.
public enum SOCKS5 {
  /// Asks the proxy on the other end of `fd` to connect to `host:port`. `host` is sent as a
  /// domain name so the phone resolves it; IP literals work the same way.
  public static func connect(_ fd: Int32, host: String, port: UInt16) throws {
    let name = Array(host.utf8)
    guard !name.isEmpty, name.count <= 255 else { throw LinkError("invalid SOCKS5 host \(host)") }

    try greet(fd)
    try writeAll(fd, [0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xFF)])
    let reply = try readExactly(fd, 4)
    guard reply[1] == 0x00 else { throw LinkError("SOCKS5 connect to \(host):\(port) failed (code \(reply[1]))") }
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
