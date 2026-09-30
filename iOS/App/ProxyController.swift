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
  private(set) var startedAt: Date?
  /// Per-second throughput for the last `sampleWindow` seconds, oldest first.
  private(set) var samples: [ThroughputSample] = []

  struct ThroughputSample: Identifiable {
    let id: Int
    let up: Double
    let down: Double
  }

  static let sampleWindow = 60

  private var server: ProxyServer?
  private var sampleIndex = 0
  private var lastSampledAt = ContinuousClock.now
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
    stats = ProxyServer.Stats()
    samples = []
    startedAt = .now
    lastSampledAt = .now
    isRunning = true
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshStats() }
    }
    RunLoop.main.add(timer, forMode: .common)
    statsTimer = timer
  }

  func stop() {
    statsTimer?.invalidate()
    statsTimer = nil
    server?.stop()
    server = nil
    keeper.stop()
    startedAt = nil
    isRunning = false
  }

  private func refreshStats() {
    guard let server else { return }
    let previous = stats
    stats = server.currentStats()
    let now = ContinuousClock.now
    let elapsed = max((now - lastSampledAt) / .seconds(1), 0.001)
    lastSampledAt = now
    samples.append(ThroughputSample(
      id: sampleIndex,
      up: Double(stats.bytesUp &- previous.bytesUp) / elapsed,
      down: Double(stats.bytesDown &- previous.bytesDown) / elapsed
    ))
    sampleIndex += 1
    if samples.count > Self.sampleWindow {
      samples.removeFirst(samples.count - Self.sampleWindow)
    }
  }
}
