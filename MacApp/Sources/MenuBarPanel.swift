import ProxyCore
import ServiceManagement
import SwiftUI

/// The window shown from the menu bar icon: capture switch, setup steps, the iPhone link, and options.
struct MenuBarPanel: View {
  let controller: ExtensionController
  @Bindable var forwarder: PhoneForwarder
  @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      let setup = SetupChecklist(controller: controller, forwarder: forwarder)
      if !setup.isComplete {
        Divider()
        setup
      }
      Divider()
      settings
      Divider()
      HStack {
        Text("Made with ♥ in Seoul")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        Menu {
          Text("Nothering \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
          Divider()
          Link("GitHub", destination: URL(string: "https://github.com/devxoul/nothering")!)
          Divider()
          Button("Quit Nothering") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
      }
    }
    .padding(14)
    .frame(width: 300)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Nothering").font(.headline)
          Text(subtitle)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(controller.status.hasPrefix("Error") ? .red : .secondary)
            .lineLimit(3)
        }
        Spacer()
        Toggle("Nothering", isOn: Binding(get: { controller.isRunning }, set: { _ in Task { await controller.toggle() } }))
          .toggleStyle(.switch)
          .labelsHidden()
      }
      if let error = forwarder.error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      if !controller.hasTurnedOn {
        Text("macOS will ask twice to add proxies — allow both")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var subtitle: String {
    guard controller.isRunning, forwarder.link != .none else { return controller.status }
    return "\(controller.status) via \(forwarder.link.rawValue) · \(Self.describe(forwarder.stats))"
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Connect iPhone via")
        Spacer()
        Picker("Connect iPhone via", selection: $forwarder.preference) {
          ForEach(PhoneForwarder.Preference.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
      Toggle("Turn on and off with iPhone proxy", isOn: $forwarder.autoTurnOn)
      Toggle("Launch at login", isOn: Binding(get: { launchesAtLogin }, set: setLaunchesAtLogin))
    }
    .toggleStyle(.checkbox)
  }

  private func setLaunchesAtLogin(_ enabled: Bool) {
    // Re-reading the status afterwards reflects a failed (un)registration in the toggle.
    try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    launchesAtLogin = SMAppService.mainApp.status == .enabled
  }

  private static func describe(_ stats: LocalForwarder.Stats) -> String {
    let up = ByteCountFormatter.string(fromByteCount: Int64(stats.bytesUp), countStyle: .file)
    let down = ByteCountFormatter.string(fromByteCount: Int64(stats.bytesDown), countStyle: .file)
    return "↑ \(up) ↓ \(down)"
  }
}
