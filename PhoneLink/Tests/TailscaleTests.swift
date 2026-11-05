import Foundation
import PhoneLink
import Testing

@Suite struct TailscaleTests {
  @Test(arguments: [
    (Data([100, 100, 100, 100]), true),
    (Data([100, 64, 0, 0]), true),
    (Data([100, 127, 255, 255]), true),
    (Data([100, 63, 255, 255]), false),
    (Data([100, 128, 0, 0]), false),
    (Data([143, 204, 1, 45]), false),
    (Data([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] + [UInt8](repeating: 0, count: 9) + [0x53]), true),
    (Data([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE1] + [UInt8](repeating: 0, count: 10)), false),
    (Data([100, 100, 100]), false),
  ])
  func classifiesTailscaleAddresses(address: Data, isTailscale: Bool) {
    #expect(Tailscale.isTailscaleAddress(address) == isTailscale)
  }

  @Test func keepsTailscalesOwnConnectionsOffTheTunnel() {
    let routed = Data([143, 204, 1, 45])
    // With an exit node every address routes through Tailscale, but its own DERP and control-plane
    // connections still have to be able to fall back to the phone.
    #expect(!Tailscale.staysOnTunnel(routed, from: "io.tailscale.ipn.macsys.network-extension") { _ in true })
    #expect(Tailscale.staysOnTunnel(routed, from: "com.google.Chrome") { _ in true })
    #expect(!Tailscale.staysOnTunnel(routed, from: "com.google.Chrome") { _ in false })
  }

  @Test func doesNotRouteLoopbackThroughTailscale() {
    #expect(!Tailscale.routesThroughTailscale(Data([127, 0, 0, 1])))
    #expect(!Tailscale.routesThroughTailscale(Data([UInt8](repeating: 0, count: 15) + [1])))
  }
}
