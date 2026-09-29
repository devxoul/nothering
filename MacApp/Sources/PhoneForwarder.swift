import Darwin
import Foundation
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

  static let port: UInt16 = 11080
  private static let phonePort: UInt16 = 11080

  private(set) var link = Link.none
  private(set) var error: String?
  private var forwarder: LocalForwarder?
  private var monitor: Timer?

  func start() {
    let forwarder = LocalForwarder(port: Self.port) { try Self.connectToPhone() }
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
  }

  /// Re-detects the link. Probing the hotspot also serves as the keepalive iOS needs to not drop
  /// idle hotspot clients while the phone is locked.
  private func refreshLink() {
    Task.detached {
      let link: Link
      if (try? USBMux.firstUSBDeviceID()) != nil {
        link = .usb
      } else if let fd = try? Self.connectOverHotspot() {
        close(fd)
        link = .hotspot
      } else {
        link = .none
      }
      await MainActor.run { self.link = link }
    }
  }

  nonisolated private static func connectToPhone() throws -> Int32 {
    if let deviceID = try? USBMux.firstUSBDeviceID() {
      return try USBMux.connect(deviceID: deviceID, port: phonePort)
    }
    return try connectOverHotspot()
  }

  nonisolated private static func connectOverHotspot() throws -> Int32 {
    try TCP.connect(host: try Hotspot.gatewayAddress(), port: phonePort, timeout: 3)
  }
}
