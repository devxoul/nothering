import Darwin
import Foundation
import PhoneLink
import Testing

private func query(_ name: String) -> Data {
  var message: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
  for label in name.split(separator: ".") {
    message.append(UInt8(label.utf8.count))
    message += Array(label.utf8)
  }
  return Data(message + [0, 0x00, 0x01, 0x00, 0x01])
}

@Suite struct DNSTests {
  @Test func readsQueryName() {
    #expect(DNS.queryName(query("WWW.Example.com")) == "www.example.com")
    #expect(DNS.queryName(Data([0x12, 0x34])) == nil)
  }

  @Test func readsAnswerAddresses() {
    var response = [UInt8](query("example.com"))
    response[2] = 0x81
    response[3] = 0x80
    response[7] = 3
    let cname: [UInt8] = [3] + Array("cdn".utf8) + [3] + Array("net".utf8) + [0]
    response += [0xC0, 0x0C, 0x00, 0x05, 0x00, 0x01, 0, 0, 0, 60, 0, UInt8(cname.count)] + cname
    response += [0xC0, 0x29, 0x00, 0x01, 0x00, 0x01, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
    let ipv6: [UInt8] = [0x26, 0x06, 0x28, 0x00] + [UInt8](repeating: 0, count: 11) + [1]
    response += [0xC0, 0x29, 0x00, 0x1C, 0x00, 0x01, 0, 0, 0, 60, 0, 16] + ipv6

    #expect(DNS.answerAddresses(Data(response)) == [Data([93, 184, 216, 34]), Data(ipv6)])
    #expect(DNS.answerAddresses(Data(response.dropLast(8))) == [Data([93, 184, 216, 34])])
    #expect(DNS.answerAddresses(Data([0x12, 0x34])) == [])
  }

  @Test(arguments: [
    ("my-mac", true),
    ("my-mac.tail1234.ts.net", true),
    ("github.com", false),
    ("tsnet.example.com", false),
  ])
  func classifiesTailscaleNames(name: String, isTailscale: Bool) {
    #expect(DNS.isTailscaleName(name) == isTailscale)
  }

  @Test func exchangesOverTCPFraming() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { fds.forEach { close($0) } }
    let request = query("example.com")
    let response = Data([0xAB, 0xCD, 0xEF])

    Thread.detachNewThread {
      var header = [UInt8](repeating: 0, count: 2)
      _ = read(fds[1], &header, 2)
      var body = [UInt8](repeating: 0, count: Int(header[0]) << 8 | Int(header[1]))
      _ = read(fds[1], &body, body.count)
      if Data(body) == request {
        let reply: [UInt8] = [0x00, 0x03, 0xAB, 0xCD, 0xEF]
        _ = write(fds[1], reply, reply.count)
      }
    }
    #expect(try DNS.exchangeOverTCP(fds[0], query: request) == response)
  }
}
