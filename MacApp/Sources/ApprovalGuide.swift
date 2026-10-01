import AppKit
import SwiftUI

/// A floating panel beside System Settings that walks through allowing the extension,
/// since the Settings pane itself gives no hint of what to do.
@MainActor
enum ApprovalGuide {
  private static var panel: NSPanel?
  private static var timer: Timer?
  private static let progress = ApprovalProgress()

  /// Opens Login Items & Extensions. A cold-launched System Settings sometimes drops the pane and shows
  /// its main page instead, so the link is opened again once it's up; reopening an open pane is a no-op.
  static func openSettings() {
    NSWorkspace.shared.open(ExtensionController.approvalSettingsURL)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSWorkspace.shared.open(ExtensionController.approvalSettingsURL) }
  }

  static func show() {
    let panel = panel ?? makePanel()
    self.panel = panel
    progress.step = 0
    panel.contentView = NSHostingView(rootView: ApprovalGuideView(progress: progress))
    position(panel)
    panel.orderFrontRegardless()
    // System Settings opens its window asynchronously, so dock again once it's up.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { position(panel) }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
      MainActor.assumeIsolated { trackProgress() }
    }
  }

  /// Shows a short confirmation when approved, then closes.
  static func close(approved: Bool) {
    guard panel != nil else { return }
    timer?.invalidate()
    guard approved else { return dismiss() }
    progress.step = ApprovalProgress.approved
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { dismiss() }
  }

  private static func dismiss() {
    timer?.invalidate()
    panel?.close()
    panel = nil
  }

  /// Follows along from what's on screen, as clicks inside System Settings can't be observed without
  /// Accessibility access: the ⓘ sheet is a second System Settings window inside the main one, and
  /// the password prompt comes from SecurityAgent once Nothering is turned on.
  private static func trackProgress() {
    if !windowFrames(of: "com.apple.SecurityAgent").isEmpty {
      progress.step = 2
      return
    }
    let settings = windowFrames(of: "com.apple.systempreferences").sorted { $0.width * $0.height > $1.width * $1.height }
    let isSheetOpen = settings.dropFirst().contains { settings[0].contains($0) }
    if isSheetOpen {
      progress.step = 1
    } else if progress.step != 2 {
      // After the password, the sheet closes a moment before the approval is picked up.
      progress.step = 0
    }
  }

  private static func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
      styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = "Allow Nothering"
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return panel
  }

  /// Docks to the right of the System Settings window, or to its left when there's no room.
  private static func position(_ panel: NSPanel) {
    panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
    let size = panel.frame.size
    guard let screen = NSScreen.main?.visibleFrame else { return }
    guard let settings = settingsWindowFrame() else {
      panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20))
      return
    }
    let top = min(settings.maxY, screen.maxY) - size.height
    let right = settings.maxX + 12
    let left = settings.minX - 12 - size.width
    let x = right + size.width <= screen.maxX ? right : left >= screen.minX ? left : screen.maxX - size.width - 20
    panel.setFrameOrigin(NSPoint(x: x, y: top))
  }

  private static func settingsWindowFrame() -> NSRect? {
    windowFrames(of: "com.apple.systempreferences").max { $0.width * $0.height < $1.width * $1.height }
  }

  /// Frames of an app's on-screen windows. Sizes and positions don't need Screen Recording access; titles would.
  private static func windowFrames(of bundleIdentifier: String) -> [NSRect] {
    let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier))
    guard
      !pids.isEmpty,
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let primaryHeight = NSScreen.screens.first?.frame.height
    else { return [] }
    return windows.compactMap { info in
      guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
            let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"]
      else { return nil }
      // Window bounds are top-left based; AppKit frames are bottom-left based.
      return NSRect(x: x, y: primaryHeight - y - height, width: width, height: height)
    }
  }
}

/// Which step the user is on; `approved` once macOS reports the extension enabled.
@MainActor
@Observable
private final class ApprovalProgress {
  static let approved = 3
  var step = 0
}

private struct ApprovalGuideView: View {
  let progress: ApprovalProgress

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if progress.step == ApprovalProgress.approved {
        Label("Extension approved", systemImage: "checkmark.circle.fill")
          .font(.headline)
          .foregroundStyle(.green)
        Text("You're all set. Next, connect your iPhone.")
          .foregroundStyle(.secondary)
      } else {
        Text("In System Settings:").font(.headline)
        step(0, "Find **Network Extensions** and click \(Image(systemName: "info.circle")).") {
          networkExtensionsRow.opacity(progress.step == 0 ? 1 : 0.5)
        }
        step(1, "Turn on **Nothering.app**.") {
          extensionRow.opacity(progress.step == 1 ? 1 : 0.5)
        }
        step(2, "Click **Done** and enter your password if asked.")
        Button("Open System Settings Again", action: ApprovalGuide.openSettings)
          .buttonStyle(.link)
      }
    }
    .padding(18)
    .frame(width: 340, alignment: .leading)
    .animation(.default, value: progress.step)
  }

  /// Look-alikes of the rows to find in System Settings, so they're easy to spot.
  private var networkExtensionsRow: some View {
    settingsRow {
      Image(systemName: "puzzlepiece.extension.fill")
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.gradient))
      Text("Network Extensions").font(.callout)
      Spacer()
      Image(systemName: "info.circle").foregroundStyle(.secondary)
    }
  }

  private var extensionRow: some View {
    let isOn = progress.step > 1
    return settingsRow {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 0) {
        Text("Nothering.app").font(.callout)
        Text(ExtensionController.extensionIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Capsule()
        .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.3))
        .frame(width: 26, height: 15)
        .overlay(alignment: isOn ? .trailing : .leading) {
          Circle().fill(.white).padding(1.5)
        }
      Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
    }
  }

  private func settingsRow(@ViewBuilder content: () -> some View) -> some View {
    HStack(spacing: 8, content: content)
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
  }

  private func step(_ index: Int, _ text: LocalizedStringKey) -> some View {
    step(index, text) { EmptyView() }
  }

  private func step(_ index: Int, _ text: LocalizedStringKey, @ViewBuilder detail: () -> some View) -> some View {
    let isDone = index < progress.step
    let isCurrent = index == progress.step
    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      ZStack {
        Circle().fill(isDone ? Color.green : isCurrent ? Color.accentColor : Color.secondary.opacity(0.3))
        if isDone {
          Image(systemName: "checkmark").font(.caption.bold())
        } else {
          Text("\(index + 1)").font(.callout.bold())
        }
      }
      .foregroundStyle(.white)
      .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 8) {
        Text(text)
          .foregroundStyle(isCurrent ? .primary : .secondary)
          .fixedSize(horizontal: false, vertical: true)
        detail()
      }
    }
  }
}

#Preview {
  let progress = ApprovalProgress()
  progress.step = 1
  return ApprovalGuideView(progress: progress)
}
