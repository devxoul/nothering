import Foundation

/// The relays of one proxy session. The extension process outlives its sessions, so a relay still
/// open when its session stops would keep its socket until the process exits; `closeAll` ends them.
final class LiveRelays {
  private let lock = NSLock()
  private var closers: [UUID: () -> Void] = [:]
  private var isClosed = false

  /// Tracks a relay until `remove`; returns false once the session has stopped.
  func insert(_ id: UUID, close: @escaping () -> Void) -> Bool {
    lock.withLock {
      guard !isClosed else { return false }
      closers[id] = close
      return true
    }
  }

  func remove(_ id: UUID) {
    lock.withLock { _ = closers.removeValue(forKey: id) }
  }

  func closeAll() {
    let closers = lock.withLock {
      isClosed = true
      defer { self.closers.removeAll() }
      return Array(self.closers.values)
    }
    closers.forEach { $0() }
  }
}
