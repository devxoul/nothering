import Darwin
import Foundation

public enum DNS {
  /// The first question's name in a DNS message, lowercased, without the trailing dot.
  public static func queryName(_ message: Data) -> String? {
    let bytes = [UInt8](message)
    guard bytes.count > 12, Int(bytes[4]) << 8 | Int(bytes[5]) >= 1 else { return nil }
    var labels: [String] = []
    var index = 12
    while index < bytes.count {
      let length = Int(bytes[index])
      if length == 0 { return labels.joined(separator: ".").lowercased() }
      guard length < 64, index + 1 + length <= bytes.count else { return nil }
      labels.append(String(decoding: bytes[(index + 1)...(index + length)], as: UTF8.self))
      index += 1 + length
    }
    return nil
  }

  /// Names only Tailscale's MagicDNS can answer: tailnet domains and single-label short names.
  public static func isTailscaleName(_ name: String) -> Bool {
    !name.contains(".") || name == "ts.net" || name.hasSuffix(".ts.net") || name.hasSuffix(".beta.tailscale.net")
  }

  /// Sends one query over a connected stream using DNS-over-TCP framing and returns the response.
  public static func exchangeOverTCP(_ fd: Int32, query: Data) throws -> Data {
    guard query.count <= Int(UInt16.max) else { throw LinkError("DNS query too large") }
    try writeAll(fd, Data([UInt8(query.count >> 8), UInt8(query.count & 0xFF)]) + query)
    let header = try readExactly(fd, 2)
    return try readExactly(fd, Int(header[0]) << 8 | Int(header[1]))
  }

  private static func writeAll(_ fd: Int32, _ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
      guard written > 0 else { throw LinkError("DNS write: \(String(cString: strerror(errno)))") }
      offset += written
    }
  }

  private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let received = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
      guard received > 0 else { throw LinkError("DNS server closed the connection") }
      offset += received
    }
    return data
  }
}
