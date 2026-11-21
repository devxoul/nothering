import Darwin
import Foundation

/// A relay's socket to the forwarder, closed exactly once: only after its reader thread has exited and
/// no flow callback is writing to it, so a descriptor number is never reused while still in use.
final class RelaySocket {
  let fd: Int32
  private let lock = NSLock()
  private var readerExited = false
  private var writers = 0
  private var closing = false
  private var closed = false

  init(fd: Int32) {
    self.fd = fd
  }

  /// Runs `body` with the socket and returns its result, or false once the socket is closing.
  func write(_ body: (Int32) -> Bool) -> Bool {
    lock.lock()
    guard !closing else {
      lock.unlock()
      return false
    }
    writers += 1
    lock.unlock()
    let result = body(fd)
    lock.withLock {
      writers -= 1
      closeIfIdle()
    }
    return result
  }

  func readerDidExit() {
    lock.withLock {
      readerExited = true
      closeIfIdle()
    }
  }

  /// Shuts the socket down, which wakes a blocked reader or writer, and closes it once they're gone.
  func close() {
    lock.withLock {
      guard !closing else { return }
      closing = true
      shutdown(fd, SHUT_RDWR)
      closeIfIdle()
    }
  }

  private func closeIfIdle() {
    guard closing, readerExited, writers == 0, !closed else { return }
    closed = true
    Darwin.close(fd)
  }
}
