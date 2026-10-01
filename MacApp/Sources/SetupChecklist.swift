import AppKit
import SwiftUI

/// The steps between a fresh install and capturing traffic, shown in the menu bar panel until they all pass.
struct SetupChecklist: View {
  var isExtensionInstalled: Bool
  var isPhoneConnected: Bool
  var connectionMethod: String?
  var isProxyRunning: Bool
  var proxyHint: String?
  var approveExtension: () -> Void
  @Environment(\.dismiss) private var dismiss

  var isComplete: Bool { isExtensionInstalled && isPhoneConnected && isProxyRunning }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      extensionStep
      Step(
        title: connectionMethod.map { "iPhone connected (\($0))" } ?? "iPhone connected",
        status: isPhoneConnected ? .done : .pending,
        explanation: proxyHint ?? "Connect by USB or join its Personal Hotspot"
      )
      Step(
        title: "Proxy running on iPhone",
        status: isProxyRunning ? .done : .pending,
        explanation: isPhoneConnected ? proxyHint ?? "Open Nothering on your iPhone and tap Start Proxy" : nil
      )
    }
  }

  private var extensionStep: Step {
    if isExtensionInstalled {
      return Step(title: "Extension approved", status: .done)
    }
    // Closes the panel first; it would otherwise cover System Settings and the guide.
    return Step(
      title: "Approve the extension",
      status: .actionNeeded,
      explanation: "Turn on Nothering in System Settings. We'll show you where.",
      action: ("Approve…", { dismiss(); approveExtension() })
    )
  }
}

extension SetupChecklist {
  init(controller: ExtensionController, forwarder: PhoneForwarder) {
    self.init(
      isExtensionInstalled: controller.isExtensionInstalled,
      isPhoneConnected: forwarder.detected != .none || forwarder.link != .none,
      connectionMethod: [forwarder.link, forwarder.detected].first { $0 != .none }?.rawValue,
      isProxyRunning: forwarder.link != .none,
      proxyHint: forwarder.hint,
      approveExtension: controller.approveExtension
    )
  }
}

private struct Step: View {
  enum Status { case done, actionNeeded, pending }

  let title: String
  let status: Status
  var explanation: String?
  var action: (title: String, perform: () -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        icon.frame(width: 16, height: 16)
        Text(title).foregroundStyle(status == .done ? .secondary : .primary)
        Spacer(minLength: 8)
        if status == .actionNeeded, let action {
          Button(action.title, action: action.perform).controlSize(.small).buttonStyle(.borderedProminent)
        } else if status != .done, let action {
          Button(action.title, action: action.perform).controlSize(.small)
        }
      }
      if status != .done, let explanation {
        Text(explanation)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 22)
      }
    }
  }

  @ViewBuilder private var icon: some View {
    switch status {
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
    case .actionNeeded:
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Action needed")
    case .pending:
      Image(systemName: "circle").foregroundStyle(.secondary).accessibilityLabel("Not done")
    }
  }
}

#Preview {
  VStack(alignment: .leading, spacing: 14) {
    SetupChecklist(
      isExtensionInstalled: false,
      isPhoneConnected: false,
      isProxyRunning: false,
      approveExtension: {}
    )
    Divider()
    SetupChecklist(
      isExtensionInstalled: false,
      isPhoneConnected: true,
      isProxyRunning: false,
      proxyHint: "Tap Start Proxy on your iPhone",
      approveExtension: {}
    )
    Divider()
    SetupChecklist(
      isExtensionInstalled: true,
      isPhoneConnected: true,
      isProxyRunning: false,
      approveExtension: {}
    )
  }
  .padding(14)
  .frame(width: 300)
}
