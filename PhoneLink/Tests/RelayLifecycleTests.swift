import Darwin
import Foundation
import PhoneLink
import Testing

@Suite struct RelayLifecycleTests {
  @Test func closeBeforeStartStartsNoPumpsAndReleasesTheSocket() throws {
    let (socket, peer) = try makePair()
    defer { close(peer) }
    let original = try #require(inode(of: socket.fd))
    socket.readerDidExit()
    let lifecycle = RelayLifecycle(socket: socket)
    lifecycle.close { socket.close() }
    var started = false
    lifecycle.start { started = true }
    #expect(!started)
    #expect(inode(of: socket.fd) != original)
  }

  @Test func startHoldsTheSocketForItsReaderAndTeardownRunsOnce() throws {
    let (socket, peer) = try makePair()
    defer { close(peer) }
    let original = try #require(inode(of: socket.fd))
    socket.readerDidExit()
    let lifecycle = RelayLifecycle(socket: socket)
    var started = false
    lifecycle.start { started = true }
    #expect(started)
    var teardowns = 0
    lifecycle.close {
      teardowns += 1
      socket.close()
    }
    lifecycle.close { teardowns += 1 }
    #expect(teardowns == 1)
    #expect(inode(of: socket.fd) == original)
    socket.readerDidExit()
    #expect(inode(of: socket.fd) != original)
  }

  @Test func teardownWaitsForAStartUnderWay() throws {
    let (socket, peer) = try makePair()
    defer { close(peer) }
    socket.readerDidExit()
    let lifecycle = RelayLifecycle(socket: socket)
    let lock = NSLock()
    var events: [String] = []
    let inStart = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let closing = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      lifecycle.start {
        inStart.signal()
        _ = release.wait(timeout: .now() + 5)
        lock.withLock { events.append("pumps") }
      }
      done.signal()
    }
    #expect(inStart.wait(timeout: .now() + 5) == .success)
    Thread.detachNewThread {
      closing.signal()
      lifecycle.close {
        lock.withLock { events.append("teardown") }
        socket.close()
      }
      done.signal()
    }
    #expect(closing.wait(timeout: .now() + 5) == .success)
    release.signal()
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(lock.withLock { events } == ["pumps", "teardown"])
    socket.readerDidExit()
  }
}
