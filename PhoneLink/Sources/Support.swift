import Foundation

public struct LinkError: LocalizedError {
  public enum Kind {
    case generic
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
