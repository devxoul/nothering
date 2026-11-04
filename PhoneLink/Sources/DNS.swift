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

  /// The IPv4 and IPv6 addresses (A and AAAA records) in a DNS response's answer section.
  public static func answerAddresses(_ message: Data) -> [Data] {
    let bytes = [UInt8](message)
    guard bytes.count >= 12 else { return [] }
    let questions = Int(bytes[4]) << 8 | Int(bytes[5])
    let answers = Int(bytes[6]) << 8 | Int(bytes[7])
    var index = 12
    for _ in 0..<questions {
      guard let end = skipName(bytes, from: index), end + 4 <= bytes.count else { return [] }
      index = end + 4
    }
    var addresses: [Data] = []
    for _ in 0..<answers {
      guard let end = skipName(bytes, from: index), end + 10 <= bytes.count else { break }
      let type = Int(bytes[end]) << 8 | Int(bytes[end + 1])
      let length = Int(bytes[end + 8]) << 8 | Int(bytes[end + 9])
      let start = end + 10
      guard start + length <= bytes.count else { break }
      if (type == 1 && length == 4) || (type == 28 && length == 16) {
        addresses.append(Data(bytes[start..<start + length]))
      }
      index = start + length
    }
    return addresses
  }

  /// The index just past the name starting at `index`, which may end in a compression pointer.
  private static func skipName(_ bytes: [UInt8], from index: Int) -> Int? {
    var index = index
    while index < bytes.count {
      let length = Int(bytes[index])
      if length == 0 { return index + 1 }
      if length & 0xC0 == 0xC0 { return index + 2 }
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
