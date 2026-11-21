import Darwin
import Foundation

/// A socket shared by blocking readers and writers on different threads, closed exactly once: only
/// after its readers have exited and no writer is using it, so a descriptor number is never reused
/// while still in use. Whoever creates the socket is its first reader (for a relay, the SOCKS5
/// handshake); a relay's reader thread claims it later.
public final class RelaySocket: @unchecked Sendable {
  public let fd: Int32
  private let lock = NSLock()
  private var readers = 1
  private var writers = 0
  private var closing = false
  private var closed = false
  private var pendingFlowWrite: DispatchSemaphore?

  public init(fd: Int32) {
    self.fd = fd
  }

  /// Runs `body` with the socket and returns its result, or false once the socket is closing.
  public func write(_ body: (Int32) -> Bool) -> Bool {
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

  /// Begins a flow write with `start` and waits for its completion; returns whether it succeeded while
  /// the socket stayed open. `close()` ends the wait, since a stopped flow may never complete it.
  public func awaitFlowWrite(_ start: (@escaping (Error?) -> Void) -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    var succeeded = false
    let registered = lock.withLock { () -> Bool in
      guard !closing else { return false }
      pendingFlowWrite = done
      return true
    }
    guard registered else { return false }
    start { [lock] error in
      lock.withLock { succeeded = error == nil }
      done.signal()
    }
    done.wait()
    return lock.withLock {
      pendingFlowWrite = nil
      return succeeded && !closing
    }
  }

  /// Makes the caller a reader, so the socket stays open until its `readerDidExit()`; returns false
  /// once the socket is closing.
  public func claimReader() -> Bool {
    lock.withLock {
      guard !closing else { return false }
      readers += 1
      return true
    }
  }

  public func readerDidExit() {
    lock.withLock {
      readers -= 1
      closeIfIdle()
    }
  }

  /// Shuts the socket down, which wakes a blocked reader, writer or flow write, and closes it once
  /// they're gone.
  public func close() {
    lock.withLock {
      guard !closing else { return }
      closing = true
      shutdown(fd, SHUT_RDWR)
      pendingFlowWrite?.signal()
      closeIfIdle()
    }
  }

  /// Closes a socket whose relay never started reading it.
  public func discard() {
    readerDidExit()
    close()
  }

  private func closeIfIdle() {
    guard closing, readers == 0, writers == 0, !closed else { return }
    closed = true
    Darwin.close(fd)
  }
}
