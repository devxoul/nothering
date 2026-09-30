import AppKit
import SwiftUI

/// The steps between a fresh install and capturing traffic, shown in the menu bar panel until they all pass.
struct SetupChecklist: View {
  var isExtensionInstalled: Bool
  var needsApproval: Bool
  var isPhoneConnected: Bool
  var connectionMethod: String?
  var isProxyRunning: Bool
  var proxyHint: String?
  var installExtension: () -> Void

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
    if needsApproval {
      return Step(
        title: "Extension approved",
        status: .inProgress,
        explanation: "Allow Nothering in Login Items & Extensions",
        action: ("Open Settings", { NSWorkspace.shared.open(ExtensionController.approvalSettingsURL) })
      )
    }
    return Step(
      title: "Extension approved",
      status: .pending,
      explanation: "Install it, then allow it in System Settings",
      action: ("Install", installExtension)
    )
  }
}

extension SetupChecklist {
  init(controller: ExtensionController, forwarder: PhoneForwarder) {
    self.init(
      isExtensionInstalled: controller.isExtensionInstalled,
      needsApproval: controller.needsApproval,
      isPhoneConnected: forwarder.detected != .none || forwarder.link != .none,
      connectionMethod: [forwarder.link, forwarder.detected].first { $0 != .none }?.rawValue,
      isProxyRunning: forwarder.link != .none,
      proxyHint: forwarder.hint,
      installExtension: controller.installExtension
    )
  }
}

private struct Step: View {
  enum Status { case done, inProgress, pending }

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
        if status != .done, let action {
          Button(action.title, action: action.perform).controlSize(.small)
        }
      }
      if status != .done, let explanation {
        Text(explanation)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.leading, 22)
      }
    }
  }

  @ViewBuilder private var icon: some View {
    switch status {
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
    case .inProgress:
      ProgressView().controlSize(.small).accessibilityLabel("In progress")
    case .pending:
      Image(systemName: "circle").foregroundStyle(.secondary).accessibilityLabel("Not done")
    }
  }
}

#Preview {
  VStack(alignment: .leading, spacing: 14) {
    SetupChecklist(
      isExtensionInstalled: false,
      needsApproval: false,
      isPhoneConnected: false,
      isProxyRunning: false,
      installExtension: {}
    )
    Divider()
    SetupChecklist(
      isExtensionInstalled: false,
      needsApproval: true,
      isPhoneConnected: true,
      isProxyRunning: false,
      proxyHint: "Tap Start Proxy on your iPhone",
      installExtension: {}
    )
    Divider()
    SetupChecklist(
      isExtensionInstalled: true,
      needsApproval: false,
      isPhoneConnected: true,
      isProxyRunning: false,
      installExtension: {}
    )
  }
  .padding(14)
  .frame(width: 300)
}
