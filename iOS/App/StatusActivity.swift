import ActivityKit
import Foundation

/// Shows the proxy on the Lock Screen and in the Dynamic Island while it runs.
///
/// iOS can kill the app without warning, so every update expires after `staleInterval` and the app
/// keeps refreshing it. Once the app is gone the updates stop, and the widget asks the user to reopen it.
@MainActor
final class StatusActivity {
  private static let refreshInterval: Duration = .seconds(10)
  private static let staleInterval: TimeInterval = 30

  private var activity: Activity<ProxyActivityAttributes>?
  private var state = ProxyActivityAttributes.ContentState(usb: false, hotspot: false)
  private var updatedAt = ContinuousClock.now

  /// Only succeeds while the app is in the foreground. Replaces activities left by a previous launch.
  func start(startedAt: Date) {
    if activity?.activityState == .active { return }
    for leftover in Activity<ProxyActivityAttributes>.activities {
      Task { await leftover.end(nil, dismissalPolicy: .immediate) }
    }
    state = .init(usb: false, hotspot: false)
    updatedAt = .now
    activity = try? Activity.request(
      attributes: ProxyActivityAttributes(startedAt: startedAt),
      content: ActivityContent(state: state, staleDate: .now + Self.staleInterval)
    )
  }

  func update(usb: Bool, hotspot: Bool) {
    let state = ProxyActivityAttributes.ContentState(usb: usb, hotspot: hotspot)
    guard let activity, state != self.state || .now - updatedAt >= Self.refreshInterval else { return }
    self.state = state
    updatedAt = .now
    let content = ActivityContent(state: state, staleDate: .now + Self.staleInterval)
    Task { await activity.update(content) }
  }

  func stop() {
    guard let activity else { return }
    self.activity = nil
    Task { await activity.end(nil, dismissalPolicy: .immediate) }
  }

  /// Called right before the app is terminated so the widget shows it closed without waiting to go stale.
  /// The process exits as soon as this returns, so it waits briefly for the update to go through.
  func markClosed() {
    guard let activity else { return }
    let content = ActivityContent(state: state, staleDate: .now)
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
      await activity.update(content)
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)
  }
}
