import Foundation

/// Tries resolvers in order, starting with the last one that answered, so one a network blocks only
/// costs the lookups that find it out.
public final class ResolverFailover: @unchecked Sendable {
  private let resolvers: [String]
  private let lock = NSLock()
  private var preferred = 0

  public init(_ resolvers: [String]) {
    self.resolvers = resolvers
  }

  /// The first answer `attempt` gives, or nil when no resolver gave one.
  public func firstAnswer<Answer>(_ attempt: (String) -> Answer?) -> Answer? {
    let start = lock.withLock { preferred }
    for offset in resolvers.indices {
      let index = (start + offset) % resolvers.count
      if let answer = attempt(resolvers[index]) {
        lock.withLock { preferred = index }
        return answer
      }
    }
    return nil
  }
}
