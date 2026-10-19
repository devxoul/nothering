import Foundation

/// Bytes relayed per calendar day, kept on the device only. Everything relayed went out from the
/// phone's own stack, so a carrier counts it as phone data rather than Personal Hotspot data.
public struct UsageLog: Codable, Equatable, Sendable {
  public struct Day: Codable, Equatable, Sendable, Identifiable {
    /// `yyyy-MM-dd` in the calendar the bytes were recorded in.
    public let id: String
    public var bytesUp: UInt64 = 0
    public var bytesDown: UInt64 = 0

    public var bytes: UInt64 { bytesUp &+ bytesDown }
  }

  /// Days kept for the history; the all-time totals outlive them.
  public static let retention = 400

  /// Oldest first, one entry per day that saw traffic.
  public private(set) var days: [Day] = []
  public private(set) var allTimeUp: UInt64 = 0
  public private(set) var allTimeDown: UInt64 = 0

  public var allTime: UInt64 { allTimeUp &+ allTimeDown }

  public init() {}

  public mutating func record(up: UInt64, down: UInt64, at date: Date = .now, calendar: Calendar = .current) {
    guard up > 0 || down > 0 else { return }
    allTimeUp &+= up
    allTimeDown &+= down
    let id = Self.id(for: date, calendar: calendar)
    // A time zone change or clock correction can revisit an earlier day, so match any entry.
    if let index = days.lastIndex(where: { $0.id == id }) {
      days[index].bytesUp &+= up
      days[index].bytesDown &+= down
    } else {
      let index = days.firstIndex { $0.id > id } ?? days.endIndex
      days.insert(Day(id: id, bytesUp: up, bytesDown: down), at: index)
      if days.count > Self.retention {
        days.removeFirst(days.count - Self.retention)
      }
    }
  }

  /// The last `count` days ending at `date`, oldest first, with zero entries for quiet days.
  public func recentDays(_ count: Int, until date: Date = .now, calendar: Calendar = .current) -> [Day] {
    let byID = Dictionary(days.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    return (0..<count).reversed().map { offset in
      let id = Self.id(for: calendar.date(byAdding: .day, value: -offset, to: date)!, calendar: calendar)
      return byID[id] ?? Day(id: id)
    }
  }

  public func today(_ date: Date = .now, calendar: Calendar = .current) -> UInt64 {
    let id = Self.id(for: date, calendar: calendar)
    return days.last { $0.id == id }?.bytes ?? 0
  }

  public func thisMonth(_ date: Date = .now, calendar: Calendar = .current) -> UInt64 {
    let prefix = Self.id(for: date, calendar: calendar).prefix(8) // "yyyy-MM-"
    return days.filter { $0.id.hasPrefix(prefix) }.reduce(0) { $0 &+ $1.bytes }
  }

  static func id(for date: Date, calendar: Calendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
}
