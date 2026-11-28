import Darwin
import Foundation
import Testing
@testable import ProxyCore

@Suite struct SocketStreamTests {
  /// Chained one-byte reads over a full buffer used to recurse once per read and overflow the stack.
  @Test func chainsSmallReadsOverLargeBufferWithoutRecursing() async throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { Darwin.close(fds[1]) }

    // One kernel read hands the stream 64 KB, served by 64K chained reads.
    let total = 64 * 1024
    var size = Int32(total * 2)
    setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    let payload = [UInt8](repeating: 7, count: total)
    #expect(payload.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress!, total) } == total)

    let queue = DispatchQueue(label: "SocketStreamTests")
    let stream = SocketStream(fd: fds[0], queue: queue)
    defer { queue.sync { stream.cancel() } }

    let received = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
      var count = 0
      func next() {
        stream.read(minimum: 1, maximum: 1) { data, _, _ in
          guard data != nil else { return continuation.resume(returning: count) }
          count += 1
          if count == total { return continuation.resume(returning: count) }
          next()
        }
      }
      queue.async { next() }
    }
    #expect(received == total)
  }

  /// Bytes arriving while a read left part of the buffer unconsumed land after that suffix, and EOF is
  /// reported only once all of them were delivered.
  @Test func keepsOrderAcrossPartialReadsAndEOF() async throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { Darwin.close(fds[1]) }
    let peer = fds[1]
    func send(_ bytes: [UInt8]) {
      #expect(bytes.withUnsafeBytes { Darwin.write(peer, $0.baseAddress!, bytes.count) } == bytes.count)
    }
    send(Array(0..<10))

    let queue = DispatchQueue(label: "SocketStreamTests")
    let stream = SocketStream(fd: fds[0], queue: queue)
    defer { queue.sync { stream.cancel() } }

    let (prefix, rest) = await withCheckedContinuation { (continuation: CheckedContinuation<([UInt8], [[UInt8]]), Never>) in
      var prefix: [UInt8] = []
      var rest: [[UInt8]] = []
      func next(minimum: Int) {
        stream.read(minimum: minimum, maximum: 64) { data, isComplete, _ in
          rest.append(data.map { [UInt8]($0) } ?? [])
          isComplete ? continuation.resume(returning: (prefix, rest)) : next(minimum: 1)
        }
      }
      queue.async {
        // A minimum above the maximum holds the prefix back until all ten bytes are buffered.
        stream.read(minimum: 10, maximum: 4) { data, _, _ in
          prefix = data.map { [UInt8]($0) } ?? []
          send(Array(10..<20))
          shutdown(peer, SHUT_WR)
          // More than the six-byte suffix, so it completes only once the second chunk is appended to it.
          next(minimum: 16)
        }
      }
    }
    #expect(prefix == Array(0..<4))
    #expect(rest.first == Array(4..<20))
    #expect(rest.joined().elementsEqual(4..<20))
  }
}
