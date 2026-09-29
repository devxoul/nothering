import Darwin
import Foundation

struct SocketError: LocalizedError {
  let operation: String
  let code: Int32

  init(_ operation: String, code: Int32 = errno) {
    self.operation = operation
    self.code = code
  }

  var errorDescription: String? {
    "\(operation): \(String(cString: strerror(code)))"
  }
}

/// `ByteStream` over a connected non-blocking BSD socket. All state is confined to `queue`.
final class SocketStream: ByteStream {
  private static let chunkSize = 64 * 1024
  private static let maxBufferedBytes = 256 * 1024

  private let fd: Int32
  private let readSource: DispatchSourceRead
  private let writeSource: DispatchSourceWrite
  private var isReadSourceSuspended = false
  private var isWriteSourceSuspended = true
  private var isCancelled = false

  private var readBuffer = Data()
  private var reachedEOF = false
  private var readError: Error?
  private var pendingRead: (minimum: Int, maximum: Int, completion: (Data?, Bool, Error?) -> Void)?

  private var pendingWrites: [(data: Data, completion: (Error?) -> Void)] = []
  private var writeOffset = 0
  private var wantsWriteEOF = false

  init(fd: Int32, queue: DispatchQueue) {
    self.fd = fd
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
    readSource.setEventHandler { [weak self] in self?.readAvailable() }
    writeSource.setEventHandler { [weak self] in self?.flushWrites() }
    readSource.setCancelHandler { Darwin.close(fd) }
    readSource.resume()
  }

  func read(minimum: Int, maximum: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
    pendingRead = (minimum, maximum, completion)
    fulfillPendingRead()
    if pendingRead != nil, isReadSourceSuspended {
      isReadSourceSuspended = false
      readSource.resume()
    }
  }

  func write(_ data: Data, completion: @escaping (Error?) -> Void) {
    guard !isCancelled else { return completion(SocketError("write", code: ECANCELED)) }
    pendingWrites.append((data, completion))
    flushWrites()
  }

  func writeEOF() {
    wantsWriteEOF = true
    flushWrites()
  }

  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    // A suspended dispatch source must be resumed before it can be cancelled and released.
    if isWriteSourceSuspended { writeSource.resume() }
    if isReadSourceSuspended { readSource.resume() }
    writeSource.cancel()
    readSource.cancel()
    pendingRead = nil
    pendingWrites.removeAll()
  }

  // MARK: Reading

  private func readAvailable() {
    var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
    let count = Darwin.read(fd, &chunk, chunk.count)
    if count > 0 {
      readBuffer.append(chunk, count: count)
    } else if count == 0 {
      reachedEOF = true
    } else if errno != EAGAIN, errno != EINTR {
      readError = SocketError("read")
    }

    fulfillPendingRead()
    // Backpressure: stop reading from the kernel while nobody is consuming the buffer.
    let stalled = reachedEOF || readError != nil || (pendingRead == nil && readBuffer.count >= Self.maxBufferedBytes)
    if stalled, !isReadSourceSuspended, !isCancelled {
      isReadSourceSuspended = true
      readSource.suspend()
    }
  }

  private func fulfillPendingRead() {
    guard let request = pendingRead else { return }
    if let readError {
      pendingRead = nil
      return request.completion(nil, false, readError)
    }
    guard readBuffer.count >= request.minimum || reachedEOF else { return }

    let chunk = readBuffer.prefix(request.maximum)
    readBuffer.removeFirst(chunk.count)
    pendingRead = nil
    request.completion(chunk.isEmpty ? nil : Data(chunk), reachedEOF && readBuffer.isEmpty, nil)
  }

  // MARK: Writing

  private func flushWrites() {
    while let (data, completion) = pendingWrites.first {
      let written = data.withUnsafeBytes { buffer in
        Darwin.write(fd, buffer.baseAddress! + writeOffset, data.count - writeOffset)
      }
      if written < 0 {
        if errno == EAGAIN || errno == EINTR { return resumeWriteSource() }
        let error = SocketError("write")
        let failed = pendingWrites
        pendingWrites.removeAll()
        failed.forEach { $0.completion(error) }
        return
      }
      writeOffset += written
      guard writeOffset == data.count else { continue }
      pendingWrites.removeFirst()
      writeOffset = 0
      completion(nil)
    }

    if !isWriteSourceSuspended, !isCancelled {
      isWriteSourceSuspended = true
      writeSource.suspend()
    }
    if wantsWriteEOF, !isCancelled {
      wantsWriteEOF = false
      shutdown(fd, SHUT_WR)
    }
  }

  private func resumeWriteSource() {
    guard isWriteSourceSuspended, !isCancelled else { return }
    isWriteSourceSuspended = false
    writeSource.resume()
  }
}
