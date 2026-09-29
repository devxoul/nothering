import Foundation
import Network

/// Minimal bidirectional byte stream used by the relay, so the client side can be a raw socket
/// while the upstream side stays an `NWConnection`.
protocol ByteStream: AnyObject {
  /// Mirrors `NWConnection.receive`: delivers between `minimum` and `maximum` bytes, or fewer at EOF.
  func read(minimum: Int, maximum: Int, completion: @escaping (Data?, _ isComplete: Bool, Error?) -> Void)
  func write(_ data: Data, completion: @escaping (Error?) -> Void)
  /// Half-closes the write side once all pending writes are flushed.
  func writeEOF()
  func cancel()
}

extension NWConnection: ByteStream {
  func read(minimum: Int, maximum: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
    receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
      completion(data, isComplete, error)
    }
  }

  func write(_ data: Data, completion: @escaping (Error?) -> Void) {
    send(content: data, completion: .contentProcessed { completion($0) })
  }

  func writeEOF() {
    send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
  }
}
