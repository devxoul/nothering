import Darwin
import Foundation

/// Reaches the iPhone over its Personal Hotspot, where the phone is the Mac's IPv6 default router.
public enum Hotspot {
  /// The IPv6 default gateway, e.g. `fe80::141b:a0ff:fe1c:64%en0`.
  public static func gatewayAddress() throws -> String {
    let output = try run("/sbin/route", ["-n", "get", "-inet6", "default"])
    guard let line = output.split(separator: "\n").first(where: { $0.contains("gateway:") }),
          let address = line.split(separator: " ").last
    else {
      throw LinkError("no IPv6 default gateway; is the Mac joined to the iPhone's hotspot?")
    }
    return String(address)
  }
}
