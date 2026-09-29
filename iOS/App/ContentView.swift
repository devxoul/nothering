import SwiftUI

struct ContentView: View {
    @State private var controller = TunnelController()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Status", value: controller.status.label)
                    Button(controller.isRunning ? "Stop Proxy" : "Start Proxy") {
                        Task { await controller.toggle() }
                    }
                    if let error = controller.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    LabeledContent("SOCKS5", value: "172.20.10.1:1080")
                } header: {
                    Text("Connect from Mac")
                } footer: {
                    Text("Turn on Personal Hotspot, connect the Mac, then point it at this SOCKS5 address. Outbound connections use cellular only.")
                }

                Section("Traffic") {
                    LabeledContent("Active connections", value: "\(controller.stats.activeConnections)")
                    LabeledContent("Total connections", value: "\(controller.stats.totalConnections)")
                    LabeledContent("Sent", value: ByteCountFormatter.string(fromByteCount: Int64(controller.stats.bytesUp), countStyle: .binary))
                    LabeledContent("Received", value: ByteCountFormatter.string(fromByteCount: Int64(controller.stats.bytesDown), countStyle: .binary))
                }
            }
            .navigationTitle("Nothering")
            .task { await controller.load() }
        }
    }
}
