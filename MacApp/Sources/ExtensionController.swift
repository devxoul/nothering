import AppKit
import Foundation
import NetworkExtension
import Observation
import SystemExtensions

/// Installs the proxy system extension and turns the transparent proxy configuration on and off.
@MainActor
@Observable
final class ExtensionController: NSObject {
  static let extensionIdentifier = "app.nothering.mac.proxy"

  private(set) var status = "Off"
  private(set) var isRunning = false
  private var manager: NETransparentProxyManager?

  override init() {
    super.init()
    NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshStatus() }
    }
    Task { await load() }
  }

  func installExtension() {
    status = "Installing extension…"
    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  func toggle() async {
    if isRunning {
      manager?.connection.stopVPNTunnel()
      return
    }
    do {
      let manager = try await configuredManager()
      try manager.connection.startVPNTunnel()
    } catch {
      status = "Error: \(error.localizedDescription)"
    }
  }

  private func load() async {
    let managers = (try? await NETransparentProxyManager.loadAllFromPreferences()) ?? []
    for stale in managers where Self.providerIdentifier(of: stale) != Self.extensionIdentifier {
      try? await stale.removeFromPreferences()
    }
    manager = managers.first { Self.providerIdentifier(of: $0) == Self.extensionIdentifier }
    refreshStatus()
  }

  private static func providerIdentifier(of manager: NETransparentProxyManager) -> String? {
    (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
  }

  private func configuredManager() async throws -> NETransparentProxyManager {
    let manager = manager ?? NETransparentProxyManager()
    let configuration = NETunnelProviderProtocol()
    configuration.providerBundleIdentifier = Self.extensionIdentifier
    configuration.serverAddress = "iPhone"
    manager.protocolConfiguration = configuration
    manager.localizedDescription = "Nothering"
    manager.isEnabled = true
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
    self.manager = manager
    return manager
  }

  private func refreshStatus() {
    let connectionStatus = manager?.connection.status ?? .invalid
    isRunning = connectionStatus == .connected || connectionStatus == .connecting
    switch connectionStatus {
    case .connected: status = "On"
    case .connecting: status = "Turning on…"
    case .disconnecting: status = "Turning off…"
    default: if !status.hasPrefix("Error"), !status.hasPrefix("Install") { status = "Off" }
    }
  }
}

extension ExtensionController: OSSystemExtensionRequestDelegate {
  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension ext: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    .replace
  }

  nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    Task { @MainActor in
      status = "Approve the extension in System Settings"
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    Task { @MainActor in status = "Extension installed" }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    Task { @MainActor in status = "Error: \(error.localizedDescription)" }
  }
}
