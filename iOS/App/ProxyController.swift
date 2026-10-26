import Foundation
import Observation
import ProxyCore
import UIKit
import UserNotifications

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
  /// Lifetime traffic, kept across launches.
  private(set) var usage = ProxyController.loadUsage()
  /// Bytes relayed since the proxy last started, kept across launches so the last session stays visible.
  private(set) var sessionUsage = UInt64(max(0, UserDefaults.standard.integer(forKey: ProxyController.sessionUsageKey)))

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
  private let terminationAlert = TerminationAlert()
  private var statsTimer: Timer?

  /// Whether the user left the proxy on, so a relaunch after iOS terminated the app starts it again.
  private static let wasRunningKey = "wasRunning"
  private static let usageKey = "usageLog"
  private static let sessionUsageKey = "sessionUsage"
  /// Saving every tick would rewrite defaults each second; a crash loses at most this many seconds.
  private static let usageSaveInterval = 10
  private var unsavedUsageTicks = 0

  private static func loadUsage() -> UsageLog {
    guard let data = UserDefaults.standard.data(forKey: usageKey) else { return UsageLog() }
    return (try? JSONDecoder().decode(UsageLog.self, from: data)) ?? UsageLog()
  }

  private func saveUsage() {
    unsavedUsageTicks = 0
    guard let data = try? JSONEncoder().encode(usage) else { return }
    UserDefaults.standard.set(data, forKey: Self.usageKey)
    UserDefaults.standard.set(Int(clamping: sessionUsage), forKey: Self.sessionUsageKey)
  }

  private func record(up: UInt64, down: UInt64) {
    usage.record(up: up, down: down)
    sessionUsage &+= up &+ down
  }

  var shouldRestore: Bool {
    UserDefaults.standard.bool(forKey: Self.wasRunningKey)
  }

  init() {
    NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.server?.send(.terminating)
        self?.recordUsage()
        self?.saveUsage()
        self?.terminationAlert.fireNow()
      }
    }
  }

  /// Called when the app becomes active, in case the keeper stopped while the app was suspended.
  func resumeKeeper() {
    guard isRunning else { return }
    keeper.resume()
  }

  func setFocusSound(_ sound: FocusSound) {
    keeper.sound = sound
  }

  /// Asks for notification permission when turning on, and reports whether it ended up on.
  func setNotifiesOnTermination(_ enabled: Bool) async -> Bool {
    var enabled = enabled
    if enabled {
      enabled = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    UserDefaults.standard.set(enabled, forKey: TerminationAlert.enabledKey)
    if isRunning {
      terminationAlert.arm()
    } else {
      terminationAlert.disarm()
    }
    return enabled
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
    #if targetEnvironment(simulator)
      // The simulator has no cellular, and shares the Mac's ports with the menu bar app's forwarder.
      let server = ProxyServer(configuration: .init(port: 11081, requiredInterfaceType: nil))
    #else
      let server = ProxyServer()
    #endif
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
    sessionUsage = 0
    saveUsage()
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
    terminationAlert.arm()
  }

  func stop() {
    recordUsage()
    saveUsage()
    statsTimer?.invalidate()
    statsTimer = nil
    server?.send(.stopped)
    server?.stop()
    server = nil
    keeper.stop()
    terminationAlert.disarm()
    startedAt = nil
    isRunning = false
    UserDefaults.standard.set(false, forKey: Self.wasRunningKey)
  }

  private func refreshStats() {
    guard let server else { return }
    keeper.resume()
    terminationAlert.refresh()
    let previous = stats
    stats = server.currentStats()
    record(up: stats.bytesUp &- previous.bytesUp, down: stats.bytesDown &- previous.bytesDown)
    unsavedUsageTicks += 1
    if unsavedUsageTicks >= Self.usageSaveInterval {
      saveUsage()
    }
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

  /// Adds traffic since the last refresh, so stopping doesn't drop the final second.
  private func recordUsage() {
    guard let server else { return }
    let latest = server.currentStats()
    record(up: latest.bytesUp &- stats.bytesUp, down: latest.bytesDown &- stats.bytesDown)
    stats = latest
  }

  /// Counts only connections opened since the last refresh, not open ones: a Mac that vanished without
  /// a FIN leaves its event stream open forever, while a live Mac opens a probe every 10 seconds.
  private func refreshMacLinks(previous: ProxyServer.Stats, now: ContinuousClock.Instant) {
    if stats.totalUSBConnections > previous.totalUSBConnections {
      linkSeenAt[.usb] = now
    }
    if stats.totalHotspotConnections > previous.totalHotspotConnections {
      linkSeenAt[.hotspot] = now
    }
    let hadLinks = !macLinks.isEmpty
    macLinks = Set(linkSeenAt.filter { now - $0.value < Self.linkTimeout }.keys)
    // Keeping the silent audio running with no client drains the battery, so turn off once the last Mac leaves.
    if hadLinks, macLinks.isEmpty {
      stop()
    }
  }
}
