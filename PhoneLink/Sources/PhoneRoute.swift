import Darwin
import Foundation

/// The current way to reach the phone, cached so each forwarded connection doesn't re-detect it
/// (running `route` per connection is too slow when a browser opens hundreds at once).
public final class PhoneRoute: @unchecked Sendable {
  public struct RefreshResult: Sendable {
    public let diagnosis: PhoneLinkDiagnosis.Result
    fileprivate let preferenceRevision: UInt64
  }

  private static let phonePort: UInt16 = 11080
  private let lock = NSLock()
  private var usbDeviceID: Int?
  private var hotspotGateway: String?
  private var storedPreference = PhoneLinkDiagnosis.Preference.auto
  private var preferenceRevision: UInt64 = 0
  private var storedIsOnExpensiveWiFi = false
  private let probeUSB: @Sendable () -> (PhoneLinkDiagnosis.USBState, Int?)
  private let probeHotspot: @Sendable (Bool) -> (PhoneLinkDiagnosis.HotspotState, String?)

  public convenience init() {
    self.init(probeUSB: { Self.checkUSB() }, probeHotspot: { Self.checkHotspot(isOnExpensiveWiFi: $0) })
  }

  init(
    probeUSB: @escaping @Sendable () -> (PhoneLinkDiagnosis.USBState, Int?),
    probeHotspot: @escaping @Sendable (Bool) -> (PhoneLinkDiagnosis.HotspotState, String?)
  ) {
    self.probeUSB = probeUSB
    self.probeHotspot = probeHotspot
  }

  public var preference: PhoneLinkDiagnosis.Preference {
    get { lock.withLock { storedPreference } }
    set {
      lock.withLock {
        guard storedPreference != newValue else { return }
        storedPreference = newValue
        preferenceRevision &+= 1
        usbDeviceID = nil
        hotspotGateway = nil
      }
    }
  }

  public var isOnExpensiveWiFi: Bool {
    get { lock.withLock { storedIsOnExpensiveWiFi } }
    set { lock.withLock { storedIsOnExpensiveWiFi = newValue } }
  }

  @discardableResult
  public func refresh() -> RefreshResult? {
    let (preference, revision) = lock.withLock { (storedPreference, preferenceRevision) }
    let (usb, deviceID) = preference == .hotspot ? (.notFound, nil) : probeUSB()
    let shouldProbeHotspot = preference != .usb && !usb.answers
    let (hotspot, gateway) = shouldProbeHotspot ? probeHotspot(isOnExpensiveWiFi) : (.notFound, nil)
    let diagnosis = PhoneLinkDiagnosis.evaluate(preference: preference, usb: usb, hotspot: hotspot)
    return lock.withLock {
      guard revision == preferenceRevision else { return nil }
      usbDeviceID = diagnosis.link == .usb ? deviceID : nil
      hotspotGateway = diagnosis.link == .hotspot ? gateway : nil
      return RefreshResult(diagnosis: diagnosis, preferenceRevision: revision)
    }
  }

  public func isCurrent(_ result: RefreshResult) -> Bool {
    lock.withLock { result.preferenceRevision == preferenceRevision }
  }

  private static func checkUSB() -> (PhoneLinkDiagnosis.USBState, Int?) {
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

  private static func checkHotspot(isOnExpensiveWiFi: Bool) -> (PhoneLinkDiagnosis.HotspotState, String?) {
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

  public func connect() throws -> Int32 {
    do {
      return try connectUsingCache()
    } catch {
      refresh()
      return try connectUsingCache()
    }
  }

  var cachedRoute: (deviceID: Int?, gateway: String?) {
    lock.withLock { (usbDeviceID, hotspotGateway) }
  }

  private func connectUsingCache() throws -> Int32 {
    let (deviceID, gateway) = cachedRoute
    if let deviceID {
      return try USBMux.connect(deviceID: deviceID, port: Self.phonePort)
    }
    if let gateway {
      return try TCP.connect(host: gateway, port: Self.phonePort, timeout: 3)
    }
    throw LinkError("iPhone not connected")
  }
}

private extension PhoneLinkDiagnosis.USBState {
  var answers: Bool {
    if case .found(proxyAnswers: true) = self { true } else { false }
  }
}
