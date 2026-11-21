import Darwin
import Foundation
import Network
import NetworkExtension
import PhoneLink
import ProxyCore

/// Carries an app UDP flow over a framed-UDP session with the phone until the session ends or
/// `close()` ends it. Datagrams to Tailscale-routed destinations go straight into the tunnel instead.
final class DatagramFlowRelay {
  private let flow: NEAppProxyUDPFlow
  private let socket: RelaySocket
  private let tunnel: TunnelDatagrams
  private let onClose: () -> Void
  private let lock = NSLock()
  private var closed = false

  init(flow: NEAppProxyUDPFlow, fd: Int32, onClose: @escaping () -> Void) {
    self.flow = flow
    socket = RelaySocket(fd: fd)
    self.onClose = onClose
    tunnel = TunnelDatagrams { payload, address, port in
      let host: Network.NWEndpoint.Host? = address.count == 4
        ? IPv4Address(address).map { .ipv4($0) }
        : IPv6Address(address).map { .ipv6($0) }
      guard let host, let port = Network.NWEndpoint.Port(rawValue: port) else { return }
      flow.writeDatagrams([(payload, .hostPort(host: host, port: port))]) { _ in }
    }
  }

  func start() {
    readFromFlow()
    Thread.detachNewThread { [self] in readFromSocket() }
  }

  /// Ends the flow and the session. UDP has no half-close, so once either side is done nothing more
  /// can be relayed, and an app's flow may never finish its pending read.
  func close() {
    lock.lock()
    guard !closed else { return lock.unlock() }
    closed = true
    lock.unlock()
    tunnel.close()
    socket.close()
    flow.closeReadWithError(nil)
    flow.closeWriteWithError(nil)
    onClose()
  }

  private func readFromFlow() {
    flow.readDatagrams { [self] datagrams, error in
      guard error == nil, let datagrams, !datagrams.isEmpty else {
        // The phone ends the session on EOF, which ends `readFromSocket` and with it the relay.
        _ = socket.write { shutdown($0, SHUT_WR) == 0 }
        return
      }
      let written = socket.write { fd in
        for (payload, endpoint) in datagrams {
          guard case let .hostPort(host, port) = endpoint else { continue }
          if let address = host.addressData, tunnel.sendIfRouted(payload, to: address, port: port.rawValue) {
            continue
          }
          guard let frame = DatagramFrame.encode(payload, host: host, port: port) else { continue }
          guard (try? SOCKS5.writeFrame(fd, frame)) != nil else { return false }
        }
        return true
      }
      guard written else { return close() }
      readFromFlow()
    }
  }

  private func readFromSocket() {
    while let body = try? SOCKS5.readFrame(socket.fd), let frame = DatagramFrame.decode(body: body) {
      let sent = DispatchSemaphore(value: 0)
      var failed = false
      flow.writeDatagrams([(frame.payload, .hostPort(host: frame.host, port: frame.port))]) { error in
        failed = error != nil
        sent.signal()
      }
      sent.wait()
      if failed { break }
    }
    socket.readerDidExit()
    close()
  }
}
