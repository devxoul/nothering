import Darwin
import Foundation
import Network
import NetworkExtension
import os
import PhoneLink

/// Pumps bytes between an app flow and a blocking socket until both directions finish.
final class FlowRelay {
  private let flow: NEAppProxyTCPFlow
  private let fd: Int32
  private let lock = NSLock()
  private var openDirections = 2

  init(flow: NEAppProxyTCPFlow, fd: Int32) {
    self.flow = flow
    self.fd = fd
  }

  func start() {
    readFromFlow()
    Thread.detachNewThread { [self] in readFromSocket() }
  }

  private func readFromFlow() {
    flow.readData { [self] data, error in
      guard error == nil, let data, !data.isEmpty else {
        shutdown(fd, SHUT_WR)
        return directionDone()
      }
      let written = data.withUnsafeBytes { buffer -> Bool in
        var offset = 0
        while offset < buffer.count {
          let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
          guard count > 0 else { return false }
          offset += count
        }
        return true
      }
      guard written else {
        flow.closeReadWithError(nil)
        return directionDone()
      }
      readFromFlow()
    }
  }

  private func readFromSocket() {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = read(fd, &buffer, buffer.count)
      guard count > 0 else { break }
      let sent = DispatchSemaphore(value: 0)
      var failed = false
      flow.write(Data(buffer[0..<count])) { error in
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
      close(fd)
      flow.closeReadWithError(nil)
    }
  }
}
