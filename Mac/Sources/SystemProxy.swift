import Foundation
import PhoneLink

/// Points macOS's SOCKS proxy setting at the local forwarder and restores the previous settings.
///
/// Applied to every enabled network service: the effective global proxy can come from a service
/// other than the one holding the default route (e.g. an active VPN such as Tailscale).
struct SystemProxy {
  private struct Setting {
    let service: String
    let enabled: Bool
    let server: String
    let port: String
  }

  private let previous: [Setting]

  var services: [String] { previous.map(\.service) }

  init() throws {
    let list = try run("/usr/sbin/networksetup", ["-listallnetworkservices"])
    let services = list.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") }
    previous = try services.map { service in
      let current = try run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])
      let fields = Dictionary(uniqueKeysWithValues: current.split(separator: "\n").compactMap { line -> (String, String)? in
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
      })
      return Setting(service: service, enabled: fields["Enabled"] == "Yes", server: fields["Server"] ?? "", port: fields["Port"] ?? "0")
    }
  }

  func enable(port: UInt16) throws {
    for setting in previous {
      try run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", setting.service, "127.0.0.1", String(port)])
      try run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", setting.service, "on"])
    }
  }

  func restore() {
    for setting in previous {
      if setting.enabled, !setting.server.isEmpty {
        _ = try? run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", setting.service, setting.server, setting.port])
      } else {
        _ = try? run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", setting.service, "off"])
      }
    }
  }
}
