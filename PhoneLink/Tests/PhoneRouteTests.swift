import Dispatch
@testable import PhoneLink
import Testing

@Suite struct PhoneRouteTests {
  @Test func dropsAnOlderHotspotProbeAfterSelectingUSB() async throws {
    let hotspotStarted = DispatchSemaphore(value: 0)
    let finishHotspot = DispatchSemaphore(value: 0)
    let route = PhoneRoute(
      probeUSB: { (.found(proxyAnswers: true), 7) },
      probeHotspot: { _ in
        hotspotStarted.signal()
        guard finishHotspot.wait(timeout: .now() + 5) == .success else {
          return (.notFound, nil)
        }
        return (.found(proxyAnswers: true), "hotspot")
      }
    )
    route.preference = .hotspot
    let lateProbe = Task.detached { route.refresh() }
    let started = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: hotspotStarted.wait(timeout: .now() + 5) == .success)
      }
    }
    try #require(started)

    route.preference = .usb
    let current = route.refresh()
    finishHotspot.signal()
    let late = await lateProbe.value

    #expect(current?.diagnosis.link == .usb)
    #expect(late == nil)
    #expect(route.cachedRoute.deviceID == 7)
    #expect(route.cachedRoute.gateway == nil)
  }

  @Test func clearsCachedRouteAndInvalidatesPublishedResultsWhenPreferenceChanges() throws {
    let route = PhoneRoute(
      probeUSB: { (.notFound, nil) },
      probeHotspot: { _ in (.found(proxyAnswers: true), "hotspot") }
    )
    route.preference = .hotspot
    let previous = try #require(route.refresh())
    #expect(route.cachedRoute.gateway == "hotspot")
    #expect(route.isCurrent(previous))

    route.preference = .usb
    #expect(route.cachedRoute.gateway == nil)
    #expect(!route.isCurrent(previous))
    #expect(route.refresh()?.diagnosis.link == PhoneLinkDiagnosis.Transport.none)

    route.preference = .hotspot
    #expect(!route.isCurrent(previous))
  }
}
