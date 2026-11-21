import Darwin
import Foundation
import Network
import NetworkExtension
import PhoneLink
import ProxyCore

/// Carries an app UDP flow over a framed-UDP session with the phone until the session ends or
/// `close()` ends it. Datagrams to Tailscale-routed destinations go straight into the tunnel instead.
final class DatagramFlowRelay: SessionRelay {
  private let flow: NEAppProxyUDPFlow
  private let socket: RelaySocket
  private let tunnel: TunnelDatagrams
  private let onClose: () -> Void
  private let lifecycle: RelayLifecycle

  init(flow: NEAppProxyUDPFlow, socket: RelaySocket, onClose: @escaping () -> Void) {
    self.flow = flow
    self.socket = socket
    self.onClose = onClose
    lifecycle = RelayLifecycle(socket: socket)
    tunnel = TunnelDatagrams { payload, address, port in
      let host: Network.NWEndpoint.Host? = address.count == 4
        ? IPv4Address(address).map { .ipv4($0) }
        : IPv6Address(address).map { .ipv6($0) }
      guard let host, let port = Network.NWEndpoint.Port(rawValue: port) else { return }
      flow.writeDatagrams([(payload, .hostPort(host: host, port: port))]) { _ in }
    }
  }

  func start() {
    lifecycle.start {
      readFromFlow()
      Thread.detachNewThread { [self] in readFromSocket() }
    }
  }

  /// Ends the flow and the session. UDP has no half-close, so once either side is done nothing more
  /// can be relayed, and an app's flow may never finish its pending read.
  func close() {
    lifecycle.close {
      tunnel.close()
      socket.close()
      flow.closeReadWithError(nil)
      flow.closeWriteWithError(nil)
      onClose()
    }
  }

  private func readFromFlow() {
    flow.readDatagrams { [self] datagrams, error in
      guard error == nil, let datagrams, !datagrams.isEmpty else {
        // The phone ends the session on EOF, which ends `readFromSocket` and with it the relay.
        _ = socket.write { shutdown($0, SHUT_WR) == 0 }
        return
      }
      for (payload, endpoint) in datagrams {
        guard case let .hostPort(host, port) = endpoint else { continue }
        if let address = host.addressData, tunnel.sendIfRouted(payload, to: address, port: port.rawValue) {
          continue
        }
        guard let frame = DatagramFrame.encode(payload, host: host, port: port) else { continue }
        guard socket.write({ (try? SOCKS5.writeFrame($0, frame)) != nil }) else { return close() }
      }
      readFromFlow()
    }
  }

  private func readFromSocket() {
    while let body = try? SOCKS5.readFrame(socket.fd), let frame = DatagramFrame.decode(body: body) {
      let datagram = (frame.payload, Network.NWEndpoint.hostPort(host: frame.host, port: frame.port))
      guard socket.awaitFlowWrite({ flow.writeDatagrams([datagram], completionHandler: $0) }) else { break }
    }
    socket.readerDidExit()
    close()
  }
}
