import ActivityKit
import Foundation

/// Shared by the app, which drives the Live Activity, and the widget extension, which renders it.
struct ProxyActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// Whether the Mac is connected over each link.
    var usb: Bool
    var hotspot: Bool
  }

  var startedAt: Date
}
