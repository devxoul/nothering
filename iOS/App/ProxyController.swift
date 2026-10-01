import Foundation
import Observation
import ProxyCore
import UIKit

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
  /// Links the Mac had a connection on within the last `linkTimeout`.
  private(set) var macLinks: Set<ProxyServer.Link> = []

  struct ThroughputSample: Identifiable {
    let id: Int
    let up: Double
    let down: Double
  }

  static let sampleWindow = 60
  /// The Mac keeps connections open only while traffic flows and probes the phone every 10 seconds,
  /// so a link stays connected for a while after its last connection.
  private static let linkTimeout: Duration = .seconds(15)

  private var server: ProxyServer?
  private var sampleIndex = 0
  private var lastSampledAt = ContinuousClock.now
  private var linkSeenAt: [ProxyServer.Link: ContinuousClock.Instant] = [:]
  private let keeper = BackgroundKeeper()
  private let activity = StatusActivity()
  private var statsTimer: Timer?

  /// Whether the user left the proxy on, so a relaunch after iOS terminated the app starts it again.
  private static let wasRunningKey = "wasRunning"

  var shouldRestore: Bool {
    UserDefaults.standard.bool(forKey: Self.wasRunningKey)
  }

  init() {
    NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.activity.markClosed() }
    }
  }

  /// Called when the app becomes active, in case the keeper stopped while the app was suspended.
  /// Also restarts the Live Activity, which iOS ends after 8 hours and only lets the foreground app start.
  func resumeKeeper() {
    guard isRunning, let startedAt else { return }
    keeper.resume()
    activity.start(startedAt: startedAt)
  }

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
    macLinks = []
    linkSeenAt = [:]
    let startedAt = Date.now
    self.startedAt = startedAt
    lastSampledAt = .now
    isRunning = true
    UserDefaults.standard.set(true, forKey: Self.wasRunningKey)
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshStats() }
    }
    RunLoop.main.add(timer, forMode: .common)
    statsTimer = timer
    activity.start(startedAt: startedAt)
  }

  func stop() {
    statsTimer?.invalidate()
    statsTimer = nil
    server?.stop()
    server = nil
    keeper.stop()
    activity.stop()
    startedAt = nil
    isRunning = false
    UserDefaults.standard.set(false, forKey: Self.wasRunningKey)
  }

  private func refreshStats() {
    guard let server else { return }
    keeper.resume()
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
    refreshMacLinks(previous: previous, now: now)
  }

  /// Also counts connections opened since the last refresh: hotspot probes close well within a second.
  private func refreshMacLinks(previous: ProxyServer.Stats, now: ContinuousClock.Instant) {
    if stats.activeUSBConnections > 0 || stats.totalUSBConnections > previous.totalUSBConnections {
      linkSeenAt[.usb] = now
    }
    if stats.activeHotspotConnections > 0 || stats.totalHotspotConnections > previous.totalHotspotConnections {
      linkSeenAt[.hotspot] = now
    }
    macLinks = Set(linkSeenAt.filter { now - $0.value < Self.linkTimeout }.keys)
    activity.update(usb: macLinks.contains(.usb), hotspot: macLinks.contains(.hotspot))
  }
}
