import Darwin
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
  var preference = Preference(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .auto {
    didSet {
      UserDefaults.standard.set(preference.rawValue, forKey: Self.preferenceKey)
      route.preference = preference
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

  func start() {
    route.preference = preference
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
      let result = route.refresh()
      await MainActor.run {
        let wasReachable = self.link != .none
        let isReachable = result.link != .none
        self.link = result.link
        self.detected = result.detected
        self.hint = result.hint
        if self.autoTurnOn, wasReachable != isReachable {
          self.onAutoTurnOn?(isReachable)
        }
      }
    }
  }
}

/// The current way to reach the phone, cached so each forwarded connection doesn't re-detect it
/// (running `route` per connection is too slow when a browser opens hundreds at once).
final class PhoneRoute: @unchecked Sendable {
  struct RefreshResult: Sendable {
    let link: PhoneForwarder.Link
    let detected: PhoneForwarder.Link
    let hint: String?
  }

  private static let phonePort: UInt16 = 11080
  private let lock = NSLock()
  private var usbDeviceID: Int?
  private var hotspotGateway: String?
  private var storedPreference = PhoneForwarder.Preference.auto
  private var storedIsOnExpensiveWiFi = false

  var preference: PhoneForwarder.Preference {
    get { lock.withLock { storedPreference } }
    set { lock.withLock { storedPreference = newValue } }
  }

  var isOnExpensiveWiFi: Bool {
    get { lock.withLock { storedIsOnExpensiveWiFi } }
    set { lock.withLock { storedIsOnExpensiveWiFi = newValue } }
  }

  @discardableResult
  func refresh() -> RefreshResult {
    let preference = preference
    let (usb, deviceID) = preference == .hotspot ? (.notFound, nil) : probeUSB()
    let shouldProbeHotspot = preference != .usb && !usb.answers
    let (hotspot, gateway) = shouldProbeHotspot ? probeHotspot() : (.notFound, nil)
    let diagnosis = PhoneLinkDiagnosis.evaluate(
      preference: preference.diagnosisPreference,
      usb: usb,
      hotspot: hotspot
    )
    let link = diagnosis.link.forwarderLink
    let detected = diagnosis.detected.forwarderLink
    lock.withLock {
      usbDeviceID = link == .usb ? deviceID : nil
      hotspotGateway = link == .hotspot ? gateway : nil
    }
    return RefreshResult(link: link, detected: detected, hint: diagnosis.hint)
  }

  private func probeUSB() -> (PhoneLinkDiagnosis.USBState, Int?) {
    do {
      let deviceID = try USBMux.firstUSBDeviceID()
      do {
        close(try USBMux.connect(deviceID: deviceID, port: Self.phonePort))
        return (.found(proxyAnswers: true), deviceID)
      } catch {
        return (.found(proxyAnswers: false), deviceID)
      }
    } catch let error as LinkError where error.kind == .noUSBDevice {
      return (.notFound, nil)
    } catch {
      return (.unavailable, nil)
    }
  }

  private func probeHotspot() -> (PhoneLinkDiagnosis.HotspotState, String?) {
    do {
      let gateway = try Hotspot.gatewayAddress()
      var proxyAnswers = false
      if let fd = try? TCP.connect(host: gateway, port: Self.phonePort, timeout: 1) {
        close(fd)
        proxyAnswers = true
      }
      let state = PhoneLinkDiagnosis.hotspot(
        proxyAnswers: proxyAnswers,
        isIPhoneHotspot: Hotspot.isIPhoneHotspot(),
        isOnExpensiveWiFi: isOnExpensiveWiFi
      )
      return (state, gateway)
    } catch {
      return (.notFound, nil)
    }
  }

  func connect() throws -> Int32 {
    do {
      return try connectUsingCache()
    } catch {
      refresh()
      return try connectUsingCache()
    }
  }

  private func connectUsingCache() throws -> Int32 {
    let (deviceID, gateway) = lock.withLock { (usbDeviceID, hotspotGateway) }
    if let deviceID {
      return try USBMux.connect(deviceID: deviceID, port: Self.phonePort)
    }
    if let gateway {
      return try TCP.connect(host: gateway, port: Self.phonePort, timeout: 3)
    }
    throw LinkError("iPhone not connected")
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

private extension PhoneLinkDiagnosis.USBState {
  var answers: Bool {
    if case .found(proxyAnswers: true) = self { true } else { false }
  }
}
