import Foundation
import Network

/// Nothering's SOCKS5 extension for carrying UDP inside the proxy's TCP stream, since the links to
/// the phone (usbmux, a hotspot TCP connection) only carry streams.
///
/// The client sends a request with `command` (the address is ignored). After a success reply, each
/// datagram in either direction is one frame:
///
///     length (UInt16 big-endian, of the rest) | ATYP | address | port | payload
///
/// Frames from the client name the destination; frames from the server name the peer that sent it.
public enum DatagramFrame {
  public static let command: UInt8 = 0x83

  public static func encode(_ payload: Data, host: NWEndpoint.Host, port: NWEndpoint.Port) -> Data? {
    var address: [UInt8]
    switch host {
    case let .ipv4(ipv4):
      address = [0x01] + ipv4.rawValue
    case let .ipv6(ipv6):
      address = [0x04] + ipv6.rawValue
    case let .name(name, _):
      let bytes = Array(name.utf8)
      guard !bytes.isEmpty, bytes.count <= 255 else { return nil }
      address = [0x03, UInt8(bytes.count)] + bytes
    @unknown default:
      return nil
    }
    address += [UInt8(port.rawValue >> 8), UInt8(port.rawValue & 0xFF)]
    let length = address.count + payload.count
    guard length <= Int(UInt16.max) else { return nil }
    return Data([UInt8(length >> 8), UInt8(length & 0xFF)] + address) + payload
  }

  /// Decodes a frame without its length prefix.
  public static func decode(body: Data) -> (host: NWEndpoint.Host, port: NWEndpoint.Port, payload: Data)? {
    let bytes = [UInt8](body)
    guard let type = bytes.first else { return nil }
    let host: NWEndpoint.Host
    let portIndex: Int
    switch type {
    case 0x01:
      guard bytes.count >= 7, let address = IPv4Address(Data(bytes[1..<5])) else { return nil }
      host = .ipv4(address)
      portIndex = 5
    case 0x04:
      guard bytes.count >= 19, let address = IPv6Address(Data(bytes[1..<17])) else { return nil }
      host = .ipv6(address)
      portIndex = 17
    case 0x03:
      guard bytes.count >= 2 else { return nil }
      let length = Int(bytes[1])
      guard length > 0, bytes.count >= 4 + length, let name = String(bytes: bytes[2..<(2 + length)], encoding: .utf8)
      else { return nil }
      host = NWEndpoint.Host(name)
      portIndex = 2 + length
    default:
      return nil
    }
    guard let port = NWEndpoint.Port(rawValue: UInt16(bytes[portIndex]) << 8 | UInt16(bytes[portIndex + 1])) else {
      return nil
    }
    return (host, port, Data(bytes[(portIndex + 2)...]))
  }
}
