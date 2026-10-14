import Foundation
import UserNotifications

/// Notifies the user when iOS terminates the app while the proxy is on, if they opted in.
///
/// iOS doesn't tell an app it is being killed in the background, so this keeps a notification scheduled a
/// few minutes out and pushes it back while the app runs. Once the app is gone it stops being pushed back
/// and fires.
@MainActor
final class TerminationAlert {
  static let enabledKey = "notifiesOnTermination"

  private static let identifier = "terminated"
  private static let delay: TimeInterval = 180
  private static let refreshInterval: Duration = .seconds(60)

  private let center = UNUserNotificationCenter.current()
  private var armedAt: ContinuousClock.Instant?

  private var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: Self.enabledKey)
  }

  func arm() {
    center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    guard isEnabled else { return disarm() }
    armedAt = .now
    schedule(after: Self.delay)
  }

  func refresh() {
    guard let armedAt, .now - armedAt >= Self.refreshInterval else { return }
    arm()
  }

  func disarm() {
    armedAt = nil
    center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
  }

  /// Called right before the app is terminated. The process exits as soon as this returns, so it waits
  /// briefly for the notification to be scheduled.
  func fireNow() {
    guard armedAt != nil else { return }
    let semaphore = DispatchSemaphore(value: 0)
    schedule(after: 1) { semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 2)
  }

  private func schedule(after delay: TimeInterval, completion: (@Sendable () -> Void)? = nil) {
    let content = UNMutableNotificationContent()
    content.title = String(localized: "Nothering was closed")
    content.body = String(localized: "The proxy stopped. Tap to reopen and keep it running.")
    content.sound = .default
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
    let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)
    center.add(request) { _ in completion?() }
  }
}
