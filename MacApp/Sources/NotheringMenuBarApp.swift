import SwiftUI

@main
struct NotheringMenuBarApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @State private var controller: ExtensionController
  @State private var forwarder: PhoneForwarder

  init() {
    Self.relaunchFromApplicationsIfNeeded()
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
    controller.installExtension()
    _controller = State(initialValue: controller)
    AppDelegate.controller = controller
  }

  var body: some Scene {
    MenuBarExtra("Nothering", image: controller.isRunning ? "MenuBarIcon" : "MenuBarIconOff") {
      MenuBarPanel(controller: controller, forwarder: forwarder)
    }
    .menuBarExtraStyle(.window)
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
