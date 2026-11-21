import Darwin
import Foundation
import Network
import NetworkExtension
import os
import PhoneLink

/// Pumps bytes between an app flow and a blocking socket until both directions finish, or until
/// `close()` ends it early.
final class FlowRelay: SessionRelay {
  private let flow: NEAppProxyTCPFlow
  private let socket: RelaySocket
  private let onClose: () -> Void
  private let lifecycle: RelayLifecycle
  private let lock = NSLock()
  private var openDirections = 2

  init(flow: NEAppProxyTCPFlow, socket: RelaySocket, onClose: @escaping () -> Void) {
    self.flow = flow
    self.socket = socket
    self.onClose = onClose
    lifecycle = RelayLifecycle(socket: socket)
  }

  func start() {
    lifecycle.start {
      readFromFlow()
      Thread.detachNewThread { [self] in readFromSocket() }
    }
  }

  /// Ends both directions now. A flow whose app never closes it, or whose session stopped, never
  /// completes its pending read, so waiting for both directions would hold the socket forever.
  func close() {
    lifecycle.close {
      socket.close()
      flow.closeReadWithError(nil)
      flow.closeWriteWithError(nil)
      onClose()
    }
  }

  private func readFromFlow() {
    flow.readData { [self] data, error in
      guard error == nil, let data, !data.isEmpty else {
        _ = socket.write { shutdown($0, SHUT_WR) == 0 }
        return directionDone()
      }
      let written = socket.write { fd in
        data.withUnsafeBytes { buffer -> Bool in
          var offset = 0
          while offset < buffer.count {
            let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            guard count > 0 else { return false }
            offset += count
          }
          return true
        }
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
      let count = read(socket.fd, &buffer, buffer.count)
      guard count > 0 else { break }
      let data = Data(buffer[0..<count])
      guard socket.awaitFlowWrite({ flow.write(data, withCompletionHandler: $0) }) else { break }
    }
    socket.readerDidExit()
    flow.closeWriteWithError(nil)
    directionDone()
  }

  private func directionDone() {
    lock.lock()
    openDirections -= 1
    let finished = openDirections == 0
    lock.unlock()
    if finished { close() }
  }
}
