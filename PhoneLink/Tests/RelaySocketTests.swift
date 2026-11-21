import Darwin
import Foundation
import PhoneLink
import Testing

@Suite struct RelaySocketTests {
  private func makePair() throws -> (RelaySocket, peer: Int32) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EMFILE) }
    var on: Int32 = 1
    setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return (RelaySocket(fd: fds[0]), fds[1])
  }

  @Test func closeEndsAHandshakeTheForwarderNeverAnswers() throws {
    let (socket, peer) = try makePair()
    defer { close(peer) }
    let greeted = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      greeted.signal()
      #expect(throws: LinkError.self) { try SOCKS5.greet(socket.fd) }
      finished.signal()
    }
    #expect(greeted.wait(timeout: .now() + 5) == .success)
    socket.close()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    // Still open while its reader hasn't let go, so the number can't be reused under it.
    #expect(fcntl(socket.fd, F_GETFD) != -1)
    socket.readerDidExit()
  }

  @Test func closeEndsAFlowWriteThatNeverCompletes() throws {
    let (socket, peer) = try makePair()
    defer { close(peer) }
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result: Bool?
    Thread.detachNewThread {
      let succeeded = socket.awaitFlowWrite { _ in started.signal() }
      lock.withLock { result = succeeded }
      finished.signal()
    }
    #expect(started.wait(timeout: .now() + 5) == .success)
    socket.close()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(lock.withLock { result } == false)
    socket.readerDidExit()
  }

  @Test func closesRightAwayWhileNoReaderHoldsIt() throws {
    let (socket, peer) = try makePair()
    defer { close(peer) }
    var before = stat()
    #expect(fstat(socket.fd, &before) == 0)
    socket.readerDidExit()
    socket.close()
    // Closed: the number is invalid, or already reused by another test for a different socket.
    var after = stat()
    #expect(fstat(socket.fd, &after) != 0 || after.st_ino != before.st_ino)
    #expect(!socket.claimReader())
  }

  @Test func reportsACompletedFlowWrite() throws {
    let (socket, peer) = try makePair()
    defer { close(peer) }
    #expect(socket.awaitFlowWrite { $0(nil) })
    #expect(!socket.awaitFlowWrite { $0(POSIXError(.EPIPE)) })
    socket.discard()
  }

  @Test func refusesWritesOnceClosing() throws {
    let (socket, peer) = try makePair()
    defer { close(peer) }
    socket.close()
    var ran = false
    #expect(!socket.write { _ in
      ran = true
      return true
    })
    #expect(!ran)
    #expect(!socket.awaitFlowWrite { $0(nil) })
    socket.readerDidExit()
  }
}
