import Foundation
import Observation
import ProxyCore

/// Runs the SOCKS5 server in the app process, kept alive in the background by `BackgroundKeeper`.
///
/// A packet tunnel extension can't be used here: iOS only lets it accept connections on the
/// primary interface, so Personal Hotspot and USB clients never reach it.
@MainActor
@Observable
final class ProxyController {
  private(set) var isRunning = false
  private(set) var stats = ProxyServer.Stats()
  private(set) var lastError: String?

  private var server: ProxyServer?
  private let keeper = BackgroundKeeper()
  private var statsTimer: Timer?

  func toggle() async {
    if isRunning {
      stop()
    } else {
      await start()
    }
  }

  func start() async {
    lastError = nil
    let server = ProxyServer()
    do {
      try await server.start()
      try keeper.start()
    } catch {
      server.stop()
      keeper.stop()
      lastError = error.localizedDescription
      return
    }
    self.server = server
    isRunning = true
    statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshStats() }
    }
  }

  func stop() {
    statsTimer?.invalidate()
    statsTimer = nil
    server?.stop()
    server = nil
    keeper.stop()
    isRunning = false
  }

  private func refreshStats() {
    if let server {
      stats = server.currentStats()
    }
  }
}
