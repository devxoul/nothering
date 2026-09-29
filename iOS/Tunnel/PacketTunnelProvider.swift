import NetworkExtension
import os
import ProxyCore

/// Hosts the SOCKS5 server. The tunnel itself routes nothing (the phone's own traffic is untouched);
/// it only exists so iOS keeps this process alive in the background.
final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let logger = Logger(subsystem: "com.suyeol.nothering", category: "tunnel")
  private var server: ProxyServer?

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.255"])
    ipv4.includedRoutes = []
    settings.ipv4Settings = ipv4

    Task {
      do {
        try await setTunnelNetworkSettings(settings)
        let server = ProxyServer()
        let port = try await server.start()
        self.server = server
        logger.info("proxy started on port \(port.rawValue)")
        completionHandler(nil)
      } catch {
        logger.error("failed to start: \(error.localizedDescription, privacy: .public)")
        // Plain NSError so the description survives XPC to the app's fetchLastDisconnectError.
        completionHandler(NSError(domain: "com.suyeol.nothering.tunnel", code: 1, userInfo: [
          NSLocalizedDescriptionKey: error.localizedDescription,
        ]))
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    logger.info("stopping, reason \(reason.rawValue)")
    server?.stop()
    server = nil
    completionHandler()
  }

  /// Replies to any app message with the current `ProxyServer.Stats` as JSON.
  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    let stats = server?.currentStats() ?? ProxyServer.Stats()
    completionHandler?(try? JSONEncoder().encode(stats))
  }
}
