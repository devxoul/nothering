import Foundation
import NetworkExtension
import Observation
import ProxyCore

/// Installs, starts and stops the packet tunnel configuration and polls proxy stats from it.
@MainActor
@Observable
final class TunnelController {
  private static let providerBundleIdentifier = "com.suyeol.nothering.tunnel"

  private(set) var status: NEVPNStatus = .invalid
  private(set) var stats = ProxyServer.Stats()
  private(set) var lastError: String?

  private var manager: NETunnelProviderManager?
  private var statsTimer: Timer?

  init() {
    NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshStatus() }
    }
  }

  var isRunning: Bool {
    status == .connected || status == .connecting || status == .reasserting
  }

  func load() async {
    do {
      manager = try await NETunnelProviderManager.loadAllFromPreferences().first
      refreshStatus()
    } catch {
      lastError = error.localizedDescription
    }
  }

  func toggle() async {
    lastError = nil
    if isRunning {
      manager?.connection.stopVPNTunnel()
      return
    }
    do {
      let manager = try await installedManager()
      try manager.connection.startVPNTunnel()
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func installedManager() async throws -> NETunnelProviderManager {
    let manager = manager ?? NETunnelProviderManager()
    let configuration = NETunnelProviderProtocol()
    configuration.providerBundleIdentifier = Self.providerBundleIdentifier
    configuration.serverAddress = "Personal Hotspot"
    manager.protocolConfiguration = configuration
    manager.localizedDescription = "Nothering"
    manager.isEnabled = true
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
    self.manager = manager
    refreshStatus()
    return manager
  }

  private func refreshStatus() {
    status = manager?.connection.status ?? .invalid
    if status == .connected {
      startPollingStats()
    } else {
      statsTimer?.invalidate()
      statsTimer = nil
    }
  }

  private func startPollingStats() {
    guard statsTimer == nil else { return }
    statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollStats() }
    }
    pollStats()
  }

  private func pollStats() {
    guard let session = manager?.connection as? NETunnelProviderSession else { return }
    try? session.sendProviderMessage(Data()) { [weak self] data in
      guard let data, let stats = try? JSONDecoder().decode(ProxyServer.Stats.self, from: data) else { return }
      Task { @MainActor in self?.stats = stats }
    }
  }
}

extension NEVPNStatus {
  var label: String {
    switch self {
    case .invalid: "Not installed"
    case .disconnected: "Stopped"
    case .connecting: "Starting…"
    case .connected: "Running"
    case .reasserting: "Reconnecting…"
    case .disconnecting: "Stopping…"
    @unknown default: "Unknown"
    }
  }
}
