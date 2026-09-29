import Foundation

/// Points macOS's SOCKS proxy setting for the active network service at the local forwarder,
/// and restores the previous setting afterwards.
struct SystemProxy {
  let service: String
  private let wasEnabled: Bool
  private let previousServer: String
  private let previousPort: String

  init() throws {
    service = try Self.activeService()
    let current = try run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])
    let fields = Dictionary(uniqueKeysWithValues: current.split(separator: "\n").compactMap { line -> (String, String)? in
      let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      return parts.count == 2 ? (parts[0], parts[1]) : nil
    })
    wasEnabled = fields["Enabled"] == "Yes"
    previousServer = fields["Server"] ?? ""
    previousPort = fields["Port"] ?? "0"
  }

  func enable(port: UInt16) throws {
    try run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, "127.0.0.1", String(port)])
    try run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "on"])
  }

  func restore() {
    if wasEnabled, !previousServer.isEmpty {
      _ = try? run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, previousServer, previousPort])
    } else {
      _ = try? run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
    }
  }

  /// The network service (e.g. "Wi-Fi") that owns the current default route's interface.
  private static func activeService() throws -> String {
    let route = try run("/sbin/route", ["-n", "get", "default"])
    guard let interface = route.split(separator: "\n").first(where: { $0.contains("interface:") })?
      .split(separator: " ").last.map(String.init)
    else {
      throw CLIError("no default route")
    }
    let order = try run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
    var lastService: String?
    for line in order.split(separator: "\n") {
      if line.hasPrefix("("), let close = line.firstIndex(of: ")"), !line.hasPrefix("(Hardware") {
        lastService = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
      } else if line.contains("Device: \(interface))"), let lastService {
        return lastService
      }
    }
    throw CLIError("no network service for interface \(interface)")
  }
}
