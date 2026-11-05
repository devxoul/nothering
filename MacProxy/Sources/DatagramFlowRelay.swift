import Darwin
import Foundation
import Network
import NetworkExtension
import PhoneLink
import ProxyCore

/// Carries an app UDP flow over a framed-UDP session with the phone until either side finishes.
/// Datagrams to Tailscale-routed destinations go straight into the tunnel instead.
final class DatagramFlowRelay {
  private let flow: NEAppProxyUDPFlow
  private let fd: Int32
  private let tunnel: TunnelDatagrams
  private let lock = NSLock()
  private var openDirections = 2

  init(flow: NEAppProxyUDPFlow, fd: Int32) {
    self.flow = flow
    self.fd = fd
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

  private func readFromFlow() {
    flow.readDatagrams { [self] datagrams, error in
      guard error == nil, let datagrams, !datagrams.isEmpty else {
        shutdown(fd, SHUT_WR)
        return directionDone()
      }
      do {
        for (payload, endpoint) in datagrams {
          guard case let .hostPort(host, port) = endpoint else { continue }
          if let address = host.addressData, tunnel.sendIfRouted(payload, to: address, port: port.rawValue) {
            continue
          }
          guard let frame = DatagramFrame.encode(payload, host: host, port: port) else { continue }
          try SOCKS5.writeFrame(fd, frame)
        }
      } catch {
        flow.closeReadWithError(nil)
        return directionDone()
      }
      readFromFlow()
    }
  }

  private func readFromSocket() {
    while let body = try? SOCKS5.readFrame(fd), let frame = DatagramFrame.decode(body: body) {
      let sent = DispatchSemaphore(value: 0)
      var failed = false
      flow.writeDatagrams([(frame.payload, .hostPort(host: frame.host, port: frame.port))]) { error in
        failed = error != nil
        sent.signal()
      }
      sent.wait()
      if failed { break }
    }
    flow.closeWriteWithError(nil)
    directionDone()
  }

  private func directionDone() {
    lock.lock()
    openDirections -= 1
    let finished = openDirections == 0
    lock.unlock()
    if finished {
      tunnel.close()
      close(fd)
      flow.closeReadWithError(nil)
    }
  }
}
