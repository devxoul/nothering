import Sparkle
import SwiftUI

@main
struct NotheringMenuBarApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @State private var controller: ExtensionController
  @State private var forwarder: PhoneForwarder
  private let updater: SPUStandardUpdaterController
  @State private var updateNudge: UpdateNudge

  init() {
    Self.relaunchFromApplicationsIfNeeded()
    let updateNudge = UpdateNudge()
    _updateNudge = State(initialValue: updateNudge)
    updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: updateNudge)
    let controller = ExtensionController()
    let forwarder = PhoneForwarder()
    forwarder.onAutoTurnOn = { [weak controller] isReachable in
      Task {
        if isReachable {
          await controller?.turnOnAutomatically()
        } else if controller?.isRunning == true {
          controller?.turnOff()
        }
      }
    }
    forwarder.start()
    _forwarder = State(initialValue: forwarder)
    controller.checkExtension()
    _controller = State(initialValue: controller)
    AppDelegate.controller = controller
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarPanel(controller: controller, forwarder: forwarder, updater: updater.updater, updateNudge: updateNudge)
    } label: {
      Image(nsImage: Self.menuBarIcon(isOn: controller.isRunning, showsAlert: forwarder.phoneProxyQuit))
        .accessibilityLabel("Nothering")
    }
    .menuBarExtraStyle(.window)
  }

  /// A template image can't hold a red dot, so the alert icon tints the template with the menu bar's
  /// text color itself, at draw time so it follows light and dark menu bars.
  private static func menuBarIcon(isOn: Bool, showsAlert: Bool) -> NSImage {
    let base = NSImage(resource: isOn ? .menuBarIcon : .menuBarIconOff)
    guard showsAlert else { return base }
    let image = NSImage(size: base.size, flipped: false) { rect in
      base.draw(in: rect)
      NSColor.labelColor.set()
      rect.fill(using: .sourceAtop)
      NSColor.systemRed.set()
      NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
      return true
    }
    image.isTemplate = false
    return image
  }

  /// macOS only activates system extensions from apps in /Applications, so a build run from elsewhere
  /// (e.g. DerivedData) replaces the installed copy and relaunches from there.
  private static func relaunchFromApplicationsIfNeeded() {
    let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
    let destination = URL(filePath: "/Applications").appending(path: source.lastPathComponent)
    guard source.deletingLastPathComponent().path != "/Applications" else { return }

    for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      app.forceTerminate()
    }
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
      try Process.run(URL(filePath: "/usr/bin/open"), arguments: ["-n", destination.path]).waitUntilExit()
      exit(0)
    } catch {
      NSLog("Nothering: could not relaunch from /Applications: \(error)")
    }
  }
}

/// Handles `nothering://on` and `nothering://off`, e.g. for scripts that must turn capture off.
final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor static var controller: ExtensionController?

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.scheme == "nothering" {
      Task { @MainActor in
        switch url.host {
        case "on": await Self.controller?.turnOn()
        case "off": Self.controller?.turnOff()
        default: break
        }
      }
    }
  }
}
