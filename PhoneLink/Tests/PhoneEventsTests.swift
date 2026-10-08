import Foundation
import PhoneLink
import ProxyCore
import Testing

@Suite struct PhoneQuitDetectorTests {
  @Test func clearsSwipeAwayWhenTheAppRelaunchesBetweenProbes() {
    var detector = PhoneQuitDetector()
    detector.handle(.opened)
    detector.handle(.event(.terminating))
    detector.handle(.closed)
    detector.linkChanged(wasReachable: true, isReachable: true, isPhoneAttached: true)
    #expect(detector.hasQuit)

    detector.handle(.opened)
    #expect(!detector.hasQuit)
  }

  @Test func reportsHardKillAfterAStopAndQuickRestart() {
    var detector = PhoneQuitDetector()
    detector.handle(.opened)
    detector.handle(.event(.stopped))
    detector.handle(.closed)
    detector.linkChanged(wasReachable: true, isReachable: true, isPhoneAttached: true)
    detector.handle(.opened)

    detector.handle(.closed)
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: true)
    #expect(detector.hasQuit)
  }

  @Test func staysQuietWhenTheUserStopsTheProxy() {
    var detector = PhoneQuitDetector()
    detector.handle(.opened)
    detector.handle(.event(.stopped))
    detector.handle(.closed)
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: true)
    #expect(!detector.hasQuit)
  }

  @Test(arguments: [(true, true), (false, false)])
  func reportsSilentProxyOnlyWhileThePhoneIsAttached(isPhoneAttached: Bool, hasQuit: Bool) {
    var detector = PhoneQuitDetector()
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: isPhoneAttached)
    #expect(detector.hasQuit == hasQuit)
  }

  @Test func clearsWhenAnOldPhoneAppAnswersAgain() {
    var detector = PhoneQuitDetector()
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: true)
    detector.linkChanged(wasReachable: false, isReachable: true, isPhoneAttached: true)
    #expect(!detector.hasQuit)
  }

  @Test func matchesTheServerEventBytes() {
    #expect(PhoneEvent.stopped.rawValue == ProxyEvent.stopped.rawValue)
    #expect(PhoneEvent.terminating.rawValue == ProxyEvent.terminating.rawValue)
  }
}

@Suite struct PhoneEventListenerTests {
  @Test func movesToANewLinkWhenTheOldStreamNeverEnds() async throws {
    let oldLink = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil))
    let oldPort = try await oldLink.start().rawValue
    defer { oldLink.stop() }
    let newLink = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil))
    let newPort = try await newLink.start().rawValue
    defer { newLink.stop() }
    let listener = PhoneEventListener()
    let (updates, continuation) = AsyncStream.makeStream(of: PhoneEventListener.Update.self)
    var iterator = updates.makeAsyncIterator()

    listener.listen(connect: { try TCP.connect(host: "127.0.0.1", port: oldPort) }) { continuation.yield($0) }
    #expect(await iterator.next() == .opened)
    listener.stop()
    #expect(await iterator.next() == .closed)

    listener.listen(connect: { try TCP.connect(host: "127.0.0.1", port: newPort) }) { continuation.yield($0) }
    #expect(await iterator.next() == .opened)
    newLink.send(.terminating)
    #expect(await iterator.next() == .event(.terminating))
  }
}
