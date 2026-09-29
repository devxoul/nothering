import SwiftUI

struct ContentView: View {
  @State private var controller = ProxyController()

  var body: some View {
    NavigationStack {
      List {
        Section {
          LabeledContent("Status", value: controller.isRunning ? "Running" : "Stopped")
          Button(controller.isRunning ? "Stop Proxy" : "Start Proxy") {
            Task { await controller.toggle() }
          }
          if let error = controller.lastError {
            Text(error).foregroundStyle(.red)
          }
        }

        Section {
          LabeledContent("SOCKS5 port", value: "11080")
        } header: {
          Text("Connect from Mac")
        } footer: {
          Text("Connect the Mac to this iPhone's Personal Hotspot and use the Mac's default gateway (this iPhone) as the SOCKS5 host. Outbound connections use cellular only.")
        }

        Section("Traffic") {
          LabeledContent("Active connections", value: "\(controller.stats.activeConnections)")
          LabeledContent("Total connections", value: "\(controller.stats.totalConnections)")
          LabeledContent("Sent", value: ByteCountFormatter.string(fromByteCount: Int64(controller.stats.bytesUp), countStyle: .binary))
          LabeledContent("Received", value: ByteCountFormatter.string(fromByteCount: Int64(controller.stats.bytesDown), countStyle: .binary))
        }
      }
      .navigationTitle("Nothering")
      .task {
        if CommandLine.arguments.contains("--autostart"), !controller.isRunning {
          await controller.start()
        }
      }
    }
  }
}
