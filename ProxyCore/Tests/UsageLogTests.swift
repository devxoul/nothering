import Foundation
import Testing
@testable import ProxyCore

@Suite struct UsageLogTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  @Test func groupsBytesByDay() {
    var log = UsageLog()
    log.record(up: 10, down: 100, at: date(10, 1, hour: 1), calendar: calendar)
    log.record(up: 5, down: 50, at: date(10, 1, hour: 23), calendar: calendar)
    log.record(up: 1, down: 2, at: date(10, 2), calendar: calendar)

    #expect(log.days.map(\.id) == ["2026-10-01", "2026-10-02"])
    #expect(log.days[0].bytesUp == 15)
    #expect(log.days[0].bytesDown == 150)
    #expect(log.today(date(10, 2), calendar: calendar) == 3)
    #expect(log.allTime == 168)
  }

  @Test func sumsThisMonthOnly() {
    var log = UsageLog()
    log.record(up: 0, down: 7, at: date(9, 30), calendar: calendar)
    log.record(up: 0, down: 3, at: date(10, 1), calendar: calendar)
    log.record(up: 0, down: 4, at: date(10, 5), calendar: calendar)

    #expect(log.thisMonth(date(10, 6), calendar: calendar) == 7)
    #expect(log.today(date(10, 6), calendar: calendar) == 0)
  }

  @Test func fillsQuietDaysInRecentHistory() {
    var log = UsageLog()
    log.record(up: 1, down: 1, at: date(10, 1), calendar: calendar)
    log.record(up: 2, down: 2, at: date(10, 3), calendar: calendar)

    let recent = log.recentDays(4, until: date(10, 3), calendar: calendar)
    #expect(recent.map(\.id) == ["2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03"])
    #expect(recent.map(\.bytes) == [0, 2, 0, 4])
  }

  @Test func prunesOldDaysButKeepsAllTimeTotal() {
    var log = UsageLog()
    let start = date(1, 1)
    for offset in 0..<(UsageLog.retention + 5) {
      log.record(up: 0, down: 1, at: calendar.date(byAdding: .day, value: offset, to: start)!, calendar: calendar)
    }

    #expect(log.days.count == UsageLog.retention)
    #expect(log.allTime == UInt64(UsageLog.retention + 5))
  }

  @Test func ignoresEmptyRecords() {
    var log = UsageLog()
    log.record(up: 0, down: 0, at: date(10, 1), calendar: calendar)
    #expect(log.days.isEmpty)
  }

  @Test func roundTripsThroughJSON() throws {
    var log = UsageLog()
    log.record(up: 1, down: 2, at: date(10, 1), calendar: calendar)
    let decoded = try JSONDecoder().decode(UsageLog.self, from: JSONEncoder().encode(log))
    #expect(decoded == log)
  }
}
