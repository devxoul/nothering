import Foundation
import Network
import Observation
import PhoneLink
import ProxyCore

/// Owns the link to the iPhone and serves it on 127.0.0.1:11080 for the proxy extension,
/// which is sandboxed and can't reach usbmux or pick a link itself.
@MainActor
@Observable
final class PhoneForwarder {
  enum Link: String, Sendable {
    case usb = "USB"
    case hotspot = "Hotspot"
    case none = "Not connected"
  }

  /// Which link to use; `auto` prefers USB and falls back to the hotspot.
  enum Preference: String, CaseIterable, Sendable {
    case auto = "Auto"
    case usb = "USB"
    case hotspot = "Hotspot"
  }

  private static let preferenceKey = "linkPreference"
  private static let autoTurnOnKey = "autoTurnOn"

  static let port: UInt16 = 11080

  /// The link whose Nothering proxy answers; `.none` until the phone's proxy is reachable.
  private(set) var link = Link.none
  /// How the iPhone itself is attached, whether or not its proxy is running.
  private(set) var detected = Link.none
  /// The next thing the user should do when the proxy isn't reachable, e.g. "Tap Start Proxy on your iPhone".
  private(set) var hint: String?
  private(set) var error: String?
  private(set) var stats = LocalForwarder.Stats()
  /// Whether the iPhone's proxy went away without the user stopping it, e.g. its app was swiped
  /// away or killed by iOS. Cleared once the proxy answers again.
  var phoneProxyQuit: Bool { quitDetector.hasQuit }

  func dismissPhoneProxyQuit() {
    quitDetector.dismiss()
  }
  var preference = Preference(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .auto {
    didSet {
      UserDefaults.standard.set(preference.rawValue, forKey: Self.preferenceKey)
      route.preference = preference.diagnosisPreference
      refreshLink()
    }
  }
  var autoTurnOn = UserDefaults.standard.bool(forKey: autoTurnOnKey) {
    didSet { UserDefaults.standard.set(autoTurnOn, forKey: Self.autoTurnOnKey) }
  }
  /// Called with `true` when the iPhone's proxy becomes reachable and `false` when it goes away, while
  /// `autoTurnOn` is set. Fires only on transitions, so a manual toggle sticks until the next one.
  @ObservationIgnored var onAutoTurnOn: ((Bool) -> Void)?
  private var forwarder: LocalForwarder?
  private var monitor: Timer?
  private var statsTimer: Timer?
  private let route = PhoneRoute()
  private let pathMonitor = NWPathMonitor()
  private let events = PhoneEventListener()
  private var quitDetector = PhoneQuitDetector()

  func start() {
    route.preference = preference.diagnosisPreference
    let route = route
    let forwarder = LocalForwarder(port: Self.port) { try route.connect() }
    do {
      _ = try forwarder.start()
      self.forwarder = forwarder
    } catch {
      self.error = "Forwarder: \(error.localizedDescription)"
    }
    refreshLink()
    monitor = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshLink() }
    }
    statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let forwarder = self.forwarder else { return }
        self.stats = forwarder.currentStats()
      }
    }
    pathMonitor.pathUpdateHandler = { [weak self, route] path in
      // macOS marks an iPhone's Personal Hotspot as expensive, which identifies it even on IPv6-only
      // hotspots that hand out no 172.20.10.x address.
      route.isOnExpensiveWiFi = path.isExpensive && path.usesInterfaceType(.wifi)
      Task { @MainActor in self?.refreshLink() }
    }
    pathMonitor.start(queue: .global())
  }

  /// Re-detects the link. Probing the hotspot also serves as the keepalive iOS needs to not drop
  /// idle hotspot clients while the phone is locked.
  private func refreshLink() {
    let route = route
    Task.detached {
      guard let result = route.refresh() else { return }
      await MainActor.run {
        guard route.isCurrent(result) else { return }
        let previousLink = self.link
        let link = result.diagnosis.link.forwarderLink
        let wasReachable = previousLink != .none
        let isReachable = link != .none
        self.link = link
        self.detected = result.diagnosis.detected.forwarderLink
        self.hint = result.diagnosis.hint
        self.trackPhoneProxy(previousLink: previousLink)
        if self.autoTurnOn, wasReachable != isReachable {
          self.onAutoTurnOn?(isReachable)
        }
      }
    }
  }

  private func trackPhoneProxy(previousLink: Link) {
    quitDetector.linkChanged(
      wasReachable: previousLink != .none,
      isReachable: link != .none,
      isPhoneAttached: detected != .none
    )
    // Moves the stream off a link that's gone or no longer selected. Its `.closed` refreshes again,
    // which opens the replacement on the current link.
    if link != previousLink {
      events.stop()
    }
    guard link != .none else { return }
    let route = route
    events.listen(connect: { try route.connect() }) { [weak self] update in
      // The main queue keeps updates in order, so an old stream's events never land after the
      // `.opened` of its replacement.
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.handle(update) }
      }
    }
  }

  private func handle(_ update: PhoneEventListener.Update) {
    quitDetector.handle(update)
    if update == .closed {
      refreshLink()
    }
  }
}

private extension PhoneForwarder.Preference {
  var diagnosisPreference: PhoneLinkDiagnosis.Preference {
    switch self {
    case .auto: .auto
    case .usb: .usb
    case .hotspot: .hotspot
    }
  }
}

private extension PhoneLinkDiagnosis.Transport {
  var forwarderLink: PhoneForwarder.Link {
    switch self {
    case .none: .none
    case .usb: .usb
    case .hotspot: .hotspot
    }
  }
}
