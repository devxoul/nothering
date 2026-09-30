public enum PhoneLinkDiagnosis {
  public enum Preference: Sendable {
    case auto
    case usb
    case hotspot
  }

  public enum Transport: Sendable {
    case none
    case usb
    case hotspot
  }

  public enum USBState: Sendable {
    case unavailable
    case notFound
    case found(proxyAnswers: Bool)
  }

  public enum HotspotState: Sendable {
    case notFound
    case found(proxyAnswers: Bool)
  }

  public struct Result: Equatable, Sendable {
    public let link: Transport
    public let detected: Transport
    public let hint: String?

    public init(link: Transport, detected: Transport, hint: String?) {
      self.link = link
      self.detected = detected
      self.hint = hint
    }
  }

  /// Classifies a found default gateway. One whose proxy doesn't answer counts as the phone only on an iPhone
  /// hotspot subnet, since any IPv6 router can be the gateway.
  public static func hotspot(proxyAnswers: Bool, isIPhoneHotspot: Bool) -> HotspotState {
    if proxyAnswers { return .found(proxyAnswers: true) }
    return isIPhoneHotspot ? .found(proxyAnswers: false) : .notFound
  }

  public static func evaluate(preference: Preference, usb: USBState, hotspot: HotspotState) -> Result {
    let detected = detectedTransport(usb: usb, hotspot: hotspot)
    let link = answeringTransport(preference: preference, usb: usb, hotspot: hotspot)
    return Result(link: link, detected: detected, hint: link == .none ? hint(preference: preference, usb: usb, hotspot: hotspot) : nil)
  }

  private static func detectedTransport(usb: USBState, hotspot: HotspotState) -> Transport {
    if case .found = usb { return .usb }
    if case .found = hotspot { return .hotspot }
    return .none
  }

  private static func answeringTransport(preference: Preference, usb: USBState, hotspot: HotspotState) -> Transport {
    let usbAnswers = if case .found(proxyAnswers: true) = usb { true } else { false }
    let hotspotAnswers = if case .found(proxyAnswers: true) = hotspot { true } else { false }
    switch preference {
    case .usb: return usbAnswers ? .usb : .none
    case .hotspot: return hotspotAnswers ? .hotspot : .none
    case .auto: return usbAnswers ? .usb : hotspotAnswers ? .hotspot : .none
    }
  }

  private static func hint(preference: Preference, usb: USBState, hotspot: HotspotState) -> String {
    switch preference {
    case .usb:
      if case .found = usb { return "Open Nothering on your iPhone and tap Start Proxy" }
      if case .unavailable = usb { return "USB iPhone support is unavailable. Reconnect your iPhone or restart your Mac" }
      return "Connect your iPhone over USB"
    case .hotspot:
      if case .found = hotspot { return "Open Nothering on your iPhone and tap Start Proxy" }
      return "Join your iPhone's Personal Hotspot"
    case .auto:
      if case .found = usb { return "Open Nothering on your iPhone and tap Start Proxy" }
      if case .found = hotspot { return "Open Nothering on your iPhone and tap Start Proxy" }
      if case .unavailable = usb { return "USB iPhone support is unavailable. Reconnect your iPhone or restart your Mac" }
      return "Connect your iPhone over USB or join its Personal Hotspot"
    }
  }
}
