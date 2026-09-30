import ProxyCore
import ServiceManagement
import SwiftUI

@main
struct NotheringMenuBarApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @State private var controller: ExtensionController
  @State private var forwarder: PhoneForwarder
  @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

  init() {
    Self.relaunchFromApplicationsIfNeeded()
    let controller = ExtensionController()
    let forwarder = PhoneForwarder()
    forwarder.onAutoTurnOn = { [weak controller] in
      Task { await controller?.turnOnAutomatically() }
    }
    forwarder.start()
    _forwarder = State(initialValue: forwarder)
    controller.installExtension()
    _controller = State(initialValue: controller)
    AppDelegate.controller = controller
  }

  var body: some Scene {
    MenuBarExtra("Nothering", image: controller.isRunning ? "MenuBarIcon" : "MenuBarIconOff") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Nothering").font(.headline)
            Text(controller.status).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
          }
          Spacer()
          Toggle("Nothering", isOn: Binding(get: { controller.isRunning }, set: { _ in Task { await controller.toggle() } }))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        if !controller.hasTurnedOn {
          Text("macOS will ask twice to add proxies — allow both")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        let setup = SetupChecklist(controller: controller, forwarder: forwarder)
        if !setup.isComplete {
          Divider()
          setup
        }
        Divider()
        VStack(alignment: .leading, spacing: 4) {
          Text("iPhone: \(forwarder.link.rawValue)")
          Text(Self.describe(forwarder.stats))
          if let error = forwarder.error {
            Text(error).foregroundStyle(.red)
          }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        Picker("Link", selection: $forwarder.preference) {
          ForEach(PhoneForwarder.Preference.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        Toggle("Turn on when iPhone proxy starts", isOn: $forwarder.autoTurnOn)
        Divider()
        HStack {
          Toggle("Launch at Login", isOn: Binding(get: { launchesAtLogin }, set: setLaunchesAtLogin))
          Spacer()
          Button("Quit Nothering") { NSApplication.shared.terminate(nil) }
        }
      }
      .padding(14)
      .frame(width: 300)
    }
    .menuBarExtraStyle(.window)
  }

  private func setLaunchesAtLogin(_ enabled: Bool) {
    // Re-reading the status afterwards reflects a failed (un)registration in the toggle.
    try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    launchesAtLogin = SMAppService.mainApp.status == .enabled
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

  private static func describe(_ stats: LocalForwarder.Stats) -> String {
    let up = ByteCountFormatter.string(fromByteCount: Int64(stats.bytesUp), countStyle: .file)
    let down = ByteCountFormatter.string(fromByteCount: Int64(stats.bytesDown), countStyle: .file)
    return "↑ \(up)  ↓ \(down)  ·  \(stats.activeConnections) connections"
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
