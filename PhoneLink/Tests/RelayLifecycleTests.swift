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
}
