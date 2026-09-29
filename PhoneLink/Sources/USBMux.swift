import Darwin
import Foundation

/// Minimal client for macOS `usbmuxd`, which tunnels TCP connections to ports on a USB-attached iPhone.
public enum USBMux {
  public static func firstUSBDeviceID() throws -> Int {
    let fd = try openSocket()
    defer { Darwin.close(fd) }
    let reply = try exchange(fd, ["MessageType": "ListDevices"])
    for device in reply["DeviceList"] as? [[String: Any]] ?? [] {
      let properties = device["Properties"] as? [String: Any]
      if properties?["ConnectionType"] as? String == "USB", let id = device["DeviceID"] as? Int {
        return id
      }
    }
    throw LinkError("no iPhone connected over USB")
  }

  /// Returns a socket connected to `port` on the device; after the handshake it is a plain byte stream.
  public static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
    let fd = try openSocket()
    do {
      let reply = try exchange(fd, [
        "MessageType": "Connect",
        "DeviceID": deviceID,
        "PortNumber": Int(port.byteSwapped),
      ])
      guard reply["Number"] as? Int == 0 else {
        throw LinkError("iPhone refused port \(port) over USB (usbmux result \(reply["Number"] ?? "?")). Is Nothering running?")
      }
      return fd
    } catch {
      Darwin.close(fd)
      throw error
    }
  }

  private static func openSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LinkError("socket: \(String(cString: strerror(errno)))") }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      _ = "/var/run/usbmuxd".utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else {
      Darwin.close(fd)
      throw LinkError("cannot reach usbmuxd: \(String(cString: strerror(errno)))")
    }
    return fd
  }

  /// Sends one plist message (16-byte little-endian header, type 8 = plist) and reads the reply.
  private static func exchange(_ fd: Int32, _ message: [String: Any]) throws -> [String: Any] {
    var message = message
    message["ProgName"] = "nothering"
    message["ClientVersionString"] = "nothering"
    let payload = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
    let header = [UInt32(16 + payload.count), 1, 8, 1].flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) }
    try writeAll(fd, Data(header) + payload)

    let replyHeader = try readExactly(fd, 16)
    let length = replyHeader.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    let body = try readExactly(fd, Int(length) - 16)
    guard let reply = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
      throw LinkError("unexpected usbmuxd reply")
    }
    return reply
  }

  private static func writeAll(_ fd: Int32, _ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
      guard written > 0 else { throw LinkError("usbmuxd write: \(String(cString: strerror(errno)))") }
      offset += written
    }
  }

  private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let received = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
      guard received > 0 else { throw LinkError("usbmuxd closed the connection") }
      offset += received
    }
    return data
  }
}
