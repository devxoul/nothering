import Darwin
import Foundation
import Network
import NetworkExtension
import os
import PhoneLink

/// Receives the Mac's DNS traffic so lookups can go through the phone along with TCP.
final class DNSProxyProvider: NEDNSProxyProvider {
  private let logger = Logger(subsystem: "app.nothering", category: "dns")
  private static let forwarderPort: UInt16 = 11080
  private let reachability = PhoneReachability(forwarderPort: forwarderPort)

  override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
    reachability.start()
    logger.info("DNS proxy started")
    completionHandler(nil)
  }

  override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    reachability.stop()
    completionHandler()
  }

  override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
    if let flow = flow as? NEAppProxyUDPFlow {
      DNSRelay.handle(flow, forwarderPort: Self.forwarderPort, reachability: reachability, logger: logger)
      return true
    }
    return false
  }
}
