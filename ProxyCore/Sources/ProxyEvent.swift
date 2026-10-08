/// Nothering's SOCKS5 extension for telling the Mac what the phone's app is doing, since the phone
/// can't open a connection to the Mac.
///
/// The client sends a request with `command` (the address is ignored) and keeps the connection open.
/// After a success reply, the server writes one byte per event.
public enum ProxyEvent: UInt8, Sendable {
  public static let command: UInt8 = 0x84

  /// The user stopped the proxy.
  case stopped = 0x01
  /// iOS is terminating the app, e.g. because the user swiped it away.
  case terminating = 0x02
}
