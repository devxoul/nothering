import Foundation

/// The addresses a resolver returned for each name, kept for an hour, so an address a connection
/// goes to can be checked against what that resolver gives for the name.
public final class ResolvedNames: @unchecked Sendable {
  private static let lifetime: TimeInterval = 3600
  private static let limit = 4096
  private let lock = NSLock()
  private var entries: [String: (addresses: Set<Data>, expiry: Date)] = [:]

  public init() {}

  public func record(_ addresses: [Data], for name: String) {
    guard !addresses.isEmpty else { return }
    let key = Self.key(name)
    let now = Date()
    lock.lock()
    defer { lock.unlock() }
    if entries.count >= Self.limit {
      entries = entries.filter { $0.value.expiry > now }
      if entries.count >= Self.limit { entries.removeAll() }
    }
    let current = entries[key].flatMap { $0.expiry > now ? $0.addresses : nil } ?? []
    entries[key] = (current.union(addresses), now + Self.lifetime)
  }

  public func contains(_ address: Data, for name: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[Self.key(name)], entry.expiry > Date() else { return false }
    return entry.addresses.contains(address)
  }

  private static func key(_ name: String) -> String {
    name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
  }
}
