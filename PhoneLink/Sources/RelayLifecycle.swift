import Foundation

/// Orders a relay's startup with its teardown. Once closed, a relay never starts; a start already
/// under way finishes submitting its pumps before teardown runs, and teardown then ends them.
public final class RelayLifecycle: @unchecked Sendable {
  private let socket: RelaySocket
  // Recursive, in case a pump's completion runs synchronously and closes the relay mid-start.
  private let lock = NSRecursiveLock()
  private var closed = false

  public init(socket: RelaySocket) {
    self.socket = socket
  }

  /// Runs `startPumps` unless the relay closed first, with a reader claim on the socket that the pump
  /// reading it releases with `readerDidExit()`. `startPumps` must only submit work, never wait on it.
  public func start(_ startPumps: () -> Void) {
    lock.withLock {
      guard !closed, socket.claimReader() else { return }
      startPumps()
    }
  }

  /// Runs `teardown` the first time only.
  public func close(_ teardown: () -> Void) {
    let first = lock.withLock { () -> Bool in
      guard !closed else { return false }
      closed = true
      return true
    }
    if first { teardown() }
  }
}
