import Darwin
import Foundation

/// Reaches the iPhone over its Personal Hotspot, where the phone is the Mac's default router.
public enum Hotspot {
  /// The phone's address on the hotspot: the IPv6 default gateway (e.g. `fe80::…%en0`) when the
  /// hotspot advertises IPv6, otherwise the classic IPv4 hotspot gateway in 172.20.10.0/28.
  public static func gatewayAddress() throws -> String {
    if let address = gateway(family: "-inet6") {
      return address
    }
    if let address = gateway(family: "-inet"), address.hasPrefix("172.20.10.") {
      return address
    }
    throw LinkError("no hotspot gateway; is the Mac joined to the iPhone's hotspot?")
  }

  /// Whether the Mac is on an iPhone's Personal Hotspot that routes IPv4 through 172.20.10.0/28.
  /// IPv6-only hotspots (CLAT, 192.0.0.0/29) don't, so callers also check for an expensive Wi-Fi path.
  /// Unlike `gatewayAddress()`, this doesn't take an arbitrary IPv6 router for the phone.
  public static func isIPhoneHotspot() -> Bool {
    gateway(family: "-inet")?.hasPrefix("172.20.10.") == true
  }

  private static func gateway(family: String) -> String? {
    guard let output = try? run("/sbin/route", ["-n", "get", family, "default"]),
          let line = output.split(separator: "\n").first(where: { $0.contains("gateway:") }),
          let address = line.split(separator: " ").last
    else {
      return nil
    }
    return String(address)
  }
}
