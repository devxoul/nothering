import Foundation

public struct LinkError: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
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
