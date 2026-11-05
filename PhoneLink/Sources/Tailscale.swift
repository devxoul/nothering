import Darwin
import Foundation

/// Traffic the Mac sends into Tailscale, which has to stay on the tailnet instead of going through
/// the phone: MagicDNS and split DNS answer from Tailscale's resolver, and subnet routes, app
/// connectors and exit nodes only work when the connection leaves through the tunnel.
public enum Tailscale {
  /// Whether a raw IPv4 or IPv6 address is in Tailscale's ranges: 100.64.0.0/10, which holds every
  /// node and the resolver 100.100.100.100, or fd7a:115c:a1e0::/48.
  public static func isTailscaleAddress(_ address: Data) -> Bool {
    let bytes = [UInt8](address)
    switch bytes.count {
    case 4: return bytes[0] == 100 && bytes[1] & 0xC0 == 64
    case 16: return bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
    default: return false
    }
  }

  /// Tailscale's network extension, standalone (`io.tailscale.ipn.macsys…`) or App Store build.
  public static func isTailscaleApp(_ signingIdentifier: String) -> Bool {
    signingIdentifier.lowercased().hasPrefix("io.tailscale.ipn.")
  }

  /// Whether an app's connection to a raw IPv4 or IPv6 address should go straight into the tunnel
  /// instead of through the phone. Tailscale's own connections (control plane, DERP) never do: they
  /// bind to the physical interface themselves, even with an exit node routing everything else
  /// through the tunnel, so the phone stays their fallback where the carrier blocks them.
  public static func staysOnTunnel(
    _ address: Data, from signingIdentifier: String, routes: (Data) -> Bool = routesThroughTailscale
  ) -> Bool {
    !isTailscaleApp(signingIdentifier) && routes(address)
  }

  /// Whether the Mac routes traffic to a raw IPv4 or IPv6 address through Tailscale: the route picks
  /// one of this Mac's Tailscale addresses as the source, on a `utun` interface. The interface check
  /// keeps a carrier-grade NAT address on a physical interface, also in 100.64.0.0/10, from counting.
  public static func routesThroughTailscale(_ address: Data) -> Bool {
    guard let source = sourceAddress(toward: address), isTailscaleAddress(source) else { return false }
    return interfaceName(owning: source)?.hasPrefix("utun") == true
  }

  /// The local address the routing table picks for `address`. Connecting a UDP socket only looks up
  /// the route; nothing is sent.
  private static func sourceAddress(toward address: Data) -> Data? {
    var storage = sockaddr_storage()
    let family: Int32
    switch address.count {
    case 4:
      family = AF_INET
      withUnsafeMutableBytes(of: &storage) { raw in
        let sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
        sin.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.pointee.sin_family = sa_family_t(AF_INET)
        sin.pointee.sin_port = in_port_t(53).bigEndian
        _ = address.withUnsafeBytes { memcpy(&sin.pointee.sin_addr, $0.baseAddress!, 4) }
      }
    case 16:
      family = AF_INET6
      withUnsafeMutableBytes(of: &storage) { raw in
        let sin6 = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self)
        sin6.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6.pointee.sin6_family = sa_family_t(AF_INET6)
        sin6.pointee.sin6_port = in_port_t(53).bigEndian
        _ = address.withUnsafeBytes { memcpy(&sin6.pointee.sin6_addr, $0.baseAddress!, 16) }
      }
    default:
      return nil
    }
    let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
    let connected = withUnsafePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
    }
    guard connected == 0 else { return nil }
    var local = sockaddr_storage()
    var localLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let named = withUnsafeMutablePointer(to: &local) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &localLength) }
    }
    guard named == 0 else { return nil }
    return withUnsafePointer(to: &local) { addressBytes(UnsafeRawPointer($0)) }
  }

  private static func interfaceName(owning address: Data) -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
    defer { freeifaddrs(interfaces) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
      guard let socketAddress = entry.pointee.ifa_addr else { continue }
      if addressBytes(UnsafeRawPointer(socketAddress)) == address {
        return String(cString: entry.pointee.ifa_name)
      }
    }
    return nil
  }

  private static func addressBytes(_ socketAddress: UnsafeRawPointer) -> Data? {
    switch Int32(socketAddress.load(as: sockaddr.self).sa_family) {
    case AF_INET:
      var sin = socketAddress.load(as: sockaddr_in.self)
      return Data(bytes: &sin.sin_addr, count: 4)
    case AF_INET6:
      var sin6 = socketAddress.load(as: sockaddr_in6.self)
      return Data(bytes: &sin6.sin6_addr, count: 16)
    default:
      return nil
    }
  }
}
