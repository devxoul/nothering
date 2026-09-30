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
  enum Link: String {
    case usb = "USB"
    case hotspot = "Hotspot"
    case none = "Not connected"
  }

  /// Which link to use; `auto` prefers USB and falls back to the hotspot.
  enum Preference: String, CaseIterable {
    case auto = "Auto"
    case usb = "USB"
    case hotspot = "Hotspot"
  }

  private static let preferenceKey = "linkPreference"

  static let port: UInt16 = 11080

  private(set) var link = Link.none
  private(set) var error: String?
  private(set) var stats = LocalForwarder.Stats()
  var preference = Preference(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .auto {
    didSet {
      UserDefaults.standard.set(preference.rawValue, forKey: Self.preferenceKey)
      route.preference = preference
      refreshLink()
    }
  }
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
    pathMonitor.pathUpdateHandler = { [weak self] _ in
      Task { @MainActor in self?.refreshLink() }
    }
    pathMonitor.start(queue: .global())
  }

  /// Re-detects the link. Probing the hotspot also serves as the keepalive iOS needs to not drop
  /// idle hotspot clients while the phone is locked.
  private func refreshLink() {
    let route = route
    Task.detached {
      let link = route.refresh()
      await MainActor.run { self.link = link }
    }
  }
}

/// The current way to reach the phone, cached so each forwarded connection doesn't re-detect it
/// (running `route` per connection is too slow when a browser opens hundreds at once).
final class PhoneRoute: @unchecked Sendable {
  private static let phonePort: UInt16 = 11080
  private let lock = NSLock()
  private var usbDeviceID: Int?
  private var hotspotGateway: String?
  private var storedPreference = PhoneForwarder.Preference.auto

  var preference: PhoneForwarder.Preference {
    get { lock.withLock { storedPreference } }
    set { lock.withLock { storedPreference = newValue } }
  }

  @discardableResult
  func refresh() -> PhoneForwarder.Link {
    let preference = preference
    let deviceID = preference == .hotspot ? nil : try? USBMux.firstUSBDeviceID()
    var gateway: String?
    if deviceID == nil, preference != .usb, let address = try? Hotspot.gatewayAddress(),
       let fd = try? TCP.connect(host: address, port: Self.phonePort, timeout: 3) {
      close(fd)
      gateway = address
    }
    lock.withLock {
      usbDeviceID = deviceID
      hotspotGateway = gateway
    }
    return deviceID != nil ? .usb : gateway != nil ? .hotspot : .none
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
