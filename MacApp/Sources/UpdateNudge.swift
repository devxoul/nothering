import Sparkle

/// Keeps scheduled update checks out of the way: instead of Sparkle's alert, the panel shows a nudge,
/// and tapping it brings up the update window.
@MainActor @Observable
final class UpdateNudge: NSObject, SPUStandardUserDriverDelegate {
  private(set) var availableVersion: String?

  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
    false
  }

  func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
    guard !handleShowingUpdate else { return }
    availableVersion = update.displayVersionString
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    availableVersion = nil
  }

  func standardUserDriverWillFinishUpdateSession() {
    availableVersion = nil
  }
}
