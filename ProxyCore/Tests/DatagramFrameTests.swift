import Foundation
import Network
import Testing
@testable import ProxyCore

@Suite struct DatagramFrameTests {
  @Test(arguments: [
    NWEndpoint.Host.ipv4(IPv4Address("1.2.3.4")!),
    .ipv6(IPv6Address("2001:db8::1")!),
    .name("example.com", nil),
  ])
  func roundTrips(host: NWEndpoint.Host) throws {
    let frame = try #require(DatagramFrame.encode(Data("quic".utf8), host: host, port: 443))
    #expect(Int(frame[0]) << 8 | Int(frame[1]) == frame.count - 2)
    let decoded = try #require(DatagramFrame.decode(body: frame.dropFirst(2)))
    #expect(decoded.host == host)
    #expect(decoded.port == 443)
    #expect(decoded.payload == Data("quic".utf8))
  }

  @Test func rejectsTruncatedAndUnknownFrames() {
    #expect(DatagramFrame.decode(body: Data()) == nil)
    #expect(DatagramFrame.decode(body: Data([0x01, 1, 2, 3, 4, 0])) == nil)
    #expect(DatagramFrame.decode(body: Data([0x03, 5, 0x61, 0x62])) == nil)
    #expect(DatagramFrame.decode(body: Data([0x09, 0, 0])) == nil)
  }

  @Test func rejectsOversizedPayload() {
    #expect(DatagramFrame.encode(Data(count: 65535), host: .ipv4(.loopback), port: 53) == nil)
  }
}
