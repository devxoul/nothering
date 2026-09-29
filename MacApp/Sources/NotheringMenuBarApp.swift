import SwiftUI

@main
struct NotheringMenuBarApp: App {
  @State private var controller = ExtensionController()
  @State private var forwarder: PhoneForwarder

  init() {
    let forwarder = PhoneForwarder()
    forwarder.start()
    _forwarder = State(initialValue: forwarder)
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
