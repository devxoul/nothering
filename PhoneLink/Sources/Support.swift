import Darwin
import Foundation

public struct LinkError: LocalizedError {
  public enum Kind {
    case generic
    case timedOut
    case noUSBDevice
    case usbmuxdUnavailable
  }

  public let message: String
  public let kind: Kind

  public init(_ message: String, kind: Kind = .generic) {
    self.message = message
    self.kind = kind
  }

  public var errorDescription: String? { message }
}

extension LinkError {
  /// Why a blocking read returned `result` (zero or negative). Call right after the read, for `errno`.
  static func readFailed(from peer: String, result: Int) -> LinkError {
    if result == 0 { return LinkError("\(peer) closed the connection") }
    if errno == EAGAIN { return LinkError("\(peer) timed out", kind: .timedOut) }
    return LinkError("\(peer) read: \(String(cString: strerror(errno)))")
  }
}

@discardableResult
public func run(_ executable: String, _ arguments: [String]) throws -> String {
  let process = Process()
  let pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw LinkError("\(executable) \(arguments.joined(separator: " ")) failed: \(output)")
  }
  return output
}
