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
  /// The legacy Extensions pane ID still resolves to Login Items & Extensions; `extension-points` scrolls to
  /// Extensions with the By Category tab selected.
  static let approvalSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points")!
  private static let hasTurnedOnKey = "hasTurnedOn"

  private(set) var status = "Off"
  private(set) var isRunning = false
  private(set) var isExtensionInstalled = false
  /// Whether macOS holds the extension until the user allows it in System Settings.
  private(set) var needsApproval = false
  /// Whether capture has been on before, so the user already allowed the proxy configurations macOS asks about.
  private(set) var hasTurnedOn = UserDefaults.standard.bool(forKey: hasTurnedOnKey) {
    didSet { UserDefaults.standard.set(hasTurnedOn, forKey: Self.hasTurnedOnKey) }
  }
  private var manager: NETransparentProxyManager?
  private var loading: Task<Void, Never>?
  private var isRemoving = false
  private var propertiesRequest: ObjectIdentifier?
  private var isWatchingApproval = false

  override init() {
    super.init()
    NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshStatus() }
    }
    loading = Task { await load() }
  }

  func installExtension() {
    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  /// Turns capture off, deletes both proxy configurations, and uninstalls the system extension.
  func removeExtension() async {
    await loading?.value
    status = "Removing extension…"
    manager?.connection.stopVPNTunnel()
    try? await manager?.removeFromPreferences()
    manager = nil
    let dnsProxy = NEDNSProxyManager.shared()
    try? await dnsProxy.loadFromPreferences()
    try? await dnsProxy.removeFromPreferences()
    isRemoving = true
    let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  /// Looks up the extension's state without activating it, so launching never triggers the system's approval alert.
  /// An already approved extension is re-activated to pick up a newer bundled version, which macOS does silently.
  func checkExtension() {
    let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
    request.delegate = self
    propertiesRequest = ObjectIdentifier(request)
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  /// Starts approval: activates the extension if it was never submitted (macOS then asks for approval),
  /// otherwise opens the Login Items & Extensions pane with step-by-step instructions beside it.
  func approveExtension() {
    if needsApproval {
      openApprovalSettings()
    } else {
      installExtension()
    }
  }

  private func openApprovalSettings() {
    ApprovalGuide.openSettings()
    ApprovalGuide.show()
    // Approving an extension that was already waiting doesn't call back any request, so watch for it.
    guard !isWatchingApproval else { return }
    isWatchingApproval = true
    checkExtension()
  }

  private func foundProperties(_ properties: [OSSystemExtensionProperties]) {
    let current = properties.filter { !$0.isUninstalling }
    if current.contains(where: \.isEnabled) {
      let wasApproving = needsApproval || isWatchingApproval
      isWatchingApproval = false
      needsApproval = false
      guard !isExtensionInstalled else { return }
      if wasApproving {
        isExtensionInstalled = true
        ApprovalGuide.close(approved: true)
      } else {
        installExtension()
      }
    } else {
      needsApproval = current.contains(where: \.isAwaitingUserApproval)
      if isWatchingApproval {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkExtension() }
      }
    }
  }

  func toggle() async {
    if isRunning {
      turnOff()
    } else {
      await turnOn()
    }
  }

  func turnOff() {
    manager?.connection.stopVPNTunnel()
    Task { try? await setDNSProxyEnabled(false) }
  }

  /// A DNS proxy has no start/stop; it runs whenever its (system-wide, single) configuration is enabled.
  private func setDNSProxyEnabled(_ enabled: Bool) async throws {
    let manager = NEDNSProxyManager.shared()
    try await manager.loadFromPreferences()
    let configuration = NEDNSProxyProviderProtocol()
    configuration.providerBundleIdentifier = Self.extensionIdentifier
    manager.providerProtocol = configuration
    manager.localizedDescription = "Nothering DNS"
    manager.isEnabled = enabled
    try await manager.saveToPreferences()
  }

  /// Turns capture on for the auto turn-on option. Skipped until the user has turned it on by hand once,
  /// since the first time macOS asks to allow the proxy configurations.
  func turnOnAutomatically() async {
    await loading?.value
    guard hasTurnedOn, !isRunning else { return }
    await turnOn()
  }

  func turnOn() async {
    // Waiting for the saved configuration keeps an early turn-on from saving a duplicate one.
    await loading?.value
    do {
      let manager = try await configuredManager()
      try manager.connection.startVPNTunnel()
      try await setDNSProxyEnabled(true)
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
    case .connected:
      status = "On"
      hasTurnedOn = true
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
      needsApproval = true
      openApprovalSettings()
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
    Task { @MainActor in foundProperties(properties) }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    let id = ObjectIdentifier(request)
    Task { @MainActor in
      guard id != propertiesRequest else { return }
      isExtensionInstalled = !isRemoving && result == .completed
      isRemoving = false
      needsApproval = false
      isWatchingApproval = false
      refreshStatus()
      ApprovalGuide.close(approved: isExtensionInstalled)
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    let id = ObjectIdentifier(request)
    Task { @MainActor in
      guard id != propertiesRequest else { return }
      // A failed removal leaves the extension installed.
      isExtensionInstalled = isRemoving
      isRemoving = false
      isWatchingApproval = false
      needsApproval = false
      status = "Error: \(error.localizedDescription)"
      ApprovalGuide.close(approved: false)
    }
  }
}
