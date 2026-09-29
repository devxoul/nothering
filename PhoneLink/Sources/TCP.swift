import Darwin
import Foundation

public enum TCP {
  public static func connect(host: String, port: UInt16, timeout: TimeInterval = 5) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    hints.ai_flags = AI_NUMERICSERV
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
      throw LinkError("cannot resolve \(host)")
    }
    defer { freeaddrinfo(result) }

    let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    guard fd >= 0 else { throw LinkError("socket: \(String(cString: strerror(errno)))") }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0, errno != EINPROGRESS {
      let message = String(cString: strerror(errno))
      Darwin.close(fd)
      throw LinkError("connect \(host): \(message)")
    }
    var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard poll(&pollFD, 1, Int32(timeout * 1000)) == 1,
          getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0
    else {
      Darwin.close(fd)
      throw LinkError("connect \(host): \(socketError == 0 ? "timed out" : String(cString: strerror(socketError)))")
    }
    _ = fcntl(fd, F_SETFL, flags)
    return fd
  }
}
