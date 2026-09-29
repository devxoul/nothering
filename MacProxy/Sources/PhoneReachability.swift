import Darwin
import Foundation
import Network
import NetworkExtension
import os
import PhoneLink

/// Tracks whether the app's forwarder can currently reach the phone, by periodically completing a
/// SOCKS5 greeting through it (the forwarder only answers once its upstream link is connected).
final class PhoneReachability {
  private let forwarderPort: UInt16
  private let lock = NSLock()
  private var reachable = false
  private var consecutiveFailures = 0
  private var timer: DispatchSourceTimer?

  init(forwarderPort: UInt16) {
    self.forwarderPort = forwarderPort
  }

  var isReachable: Bool {
    lock.withLock { reachable }
  }

  func start() {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now(), repeating: 3)
    timer.setEventHandler { [weak self] in self?.probe() }
    timer.resume()
    self.timer = timer
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  private func probe() {
    var result = false
    if let fd = try? TCP.connect(host: "127.0.0.1", port: forwarderPort, timeout: 2) {
      var timeout = timeval(tv_sec: 3, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      result = (try? SOCKS5.greet(fd)) != nil
      close(fd)
    }
    // Hysteresis: one slow probe under load shouldn't send every new connection around the phone.
    lock.withLock {
      consecutiveFailures = result ? 0 : consecutiveFailures + 1
      reachable = result || (reachable && consecutiveFailures < 2)
    }
  }
}
