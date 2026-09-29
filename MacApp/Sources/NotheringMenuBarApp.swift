import SwiftUI

@main
struct NotheringMenuBarApp: App {
  @State private var controller = ExtensionController()

  var body: some Scene {
    MenuBarExtra("Nothering", systemImage: controller.isRunning ? "iphone.radiowaves.left.and.right" : "iphone") {
      Text(controller.status)
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
