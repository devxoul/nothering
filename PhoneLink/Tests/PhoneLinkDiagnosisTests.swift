import PhoneLink
import Testing

@Suite struct PhoneLinkDiagnosisTests {
  @Test func doesNotReportUSBWhenItsProxyDoesNotAnswer() {
    let result = PhoneLinkDiagnosis.evaluate(
      preference: .auto,
      usb: .found(proxyAnswers: false),
      hotspot: .notFound
    )

    #expect(result.link == .none)
    #expect(result.detected == .usb)
    #expect(result.hint == "Open Nothering on your iPhone and tap Start Proxy")
  }

  @Test func autoFallsBackToAnAnsweringHotspotProxy() {
    let result = PhoneLinkDiagnosis.evaluate(
      preference: .auto,
      usb: .found(proxyAnswers: false),
      hotspot: .found(proxyAnswers: true)
    )

    #expect(result.link == .hotspot)
    #expect(result.detected == .usb)
    #expect(result.hint == nil)
  }

  @Test func asksForUSBWhenUSBIsPreferred() {
    let result = PhoneLinkDiagnosis.evaluate(
      preference: .usb,
      usb: .notFound,
      hotspot: .found(proxyAnswers: true)
    )

    #expect(result.link == .none)
    #expect(result.detected == .hotspot)
    #expect(result.hint == "Connect your iPhone over USB")
  }

  @Test func asksForPersonalHotspotWhenNoGatewayExists() {
    let result = PhoneLinkDiagnosis.evaluate(
      preference: .hotspot,
      usb: .notFound,
      hotspot: .notFound
    )

    #expect(result.link == .none)
    #expect(result.detected == .none)
    #expect(result.hint == "Join your iPhone's Personal Hotspot")
  }

  @Test func distinguishesNoIPhoneFromUnavailableUSBMux() {
    let noPhone = PhoneLinkDiagnosis.evaluate(
      preference: .auto,
      usb: .notFound,
      hotspot: .notFound
    )
    let noUSBMux = PhoneLinkDiagnosis.evaluate(
      preference: .auto,
      usb: .unavailable,
      hotspot: .notFound
    )

    #expect(noPhone.hint == "Connect your iPhone over USB or join its Personal Hotspot")
    #expect(noUSBMux.hint == "USB iPhone support is unavailable. Reconnect your iPhone or restart your Mac")
  }

  @Test func doesNotTakeAnOrdinaryIPv6RouterForTheIPhone() {
    let result = PhoneLinkDiagnosis.evaluate(
      preference: .auto,
      usb: .notFound,
      hotspot: PhoneLinkDiagnosis.hotspot(proxyAnswers: false, isIPhoneHotspot: false, isOnExpensiveWiFi: false)
    )

    #expect(result.link == .none)
    #expect(result.detected == .none)
    #expect(result.hint == "Connect your iPhone over USB or join its Personal Hotspot")
  }

  @Test func detectsAnIPhoneHotspotWhoseProxyIsStopped() {
    let result = PhoneLinkDiagnosis.evaluate(
      preference: .auto,
      usb: .notFound,
      hotspot: PhoneLinkDiagnosis.hotspot(proxyAnswers: false, isIPhoneHotspot: true, isOnExpensiveWiFi: false)
    )

    #expect(result.link == .none)
    #expect(result.detected == .hotspot)
    #expect(result.hint == "Open Nothering on your iPhone and tap Start Proxy")
  }

  @Test func detectsAnIPv6OnlyIPhoneHotspotWhoseProxyIsStopped() {
    let result = PhoneLinkDiagnosis.evaluate(
      preference: .auto,
      usb: .notFound,
      hotspot: PhoneLinkDiagnosis.hotspot(proxyAnswers: false, isIPhoneHotspot: false, isOnExpensiveWiFi: true)
    )

    #expect(result.link == .none)
    #expect(result.detected == .hotspot)
    #expect(result.hint == "Open Nothering on your iPhone and tap Start Proxy")
  }

  @Test func answeringPreferredLinksHaveNoHint() {
    let usb = PhoneLinkDiagnosis.evaluate(
      preference: .usb,
      usb: .found(proxyAnswers: true),
      hotspot: .notFound
    )
    let hotspot = PhoneLinkDiagnosis.evaluate(
      preference: .hotspot,
      usb: .notFound,
      hotspot: .found(proxyAnswers: true)
    )

    #expect(usb == .init(link: .usb, detected: .usb, hint: nil))
    #expect(hotspot == .init(link: .hotspot, detected: .hotspot, hint: nil))
  }
}
