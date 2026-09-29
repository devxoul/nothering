import SwiftUI

@main
struct NotheringMenuBarApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @State private var controller: ExtensionController
  @State private var forwarder: PhoneForwarder

  init() {
    let forwarder = PhoneForwarder()
    forwarder.start()
    _forwarder = State(initialValue: forwarder)
    let controller = ExtensionController()
    controller.installExtension()
    _controller = State(initialValue: controller)
    AppDelegate.controller = controller
  }

  var body: some Scene {
    MenuBarExtra("Nothering", systemImage: controller.isRunning ? "iphone.radiowaves.left.and.right" : "iphone") {
      Text(controller.status)
      Text("iPhone: \(forwarder.link.rawValue)")
      if let error = forwarder.error {
        Text(error)
      }
      Divider()
      Button("Install Extension") { controller.installExtension() }
      Button(controller.isRunning ? "Turn Off" : "Turn On") {
        Task { await controller.toggle() }
      }
      Divider()
      Button("Quit Nothering") { NSApplication.shared.terminate(nil) }
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
