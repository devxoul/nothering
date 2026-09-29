import Darwin
import Foundation
import PhoneLink
import ProxyCore

let usage = """
  usage: nothering [--via auto|usb|hotspot] [--port 11080] [--host <phone address>] [--system-proxy]

  Forwards 127.0.0.1:<port> to the Nothering proxy on the iPhone.
    --via           link to the iPhone (auto tries USB first, then hotspot)
    --host          phone address for the hotspot link (default: the Mac's IPv6 default gateway)
    --system-proxy  point macOS's SOCKS proxy at the forwarder while running
  If nothering is killed without cleanup, reset with:
    networksetup -setsocksfirewallproxystate <service> off   (for each service)
  """

setvbuf(stdout, nil, _IOLBF, 0)

var via = "auto"
var port: UInt16 = 11080
var host: String?
var useSystemProxy = false

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
  switch argument {
  case "--via": via = arguments.next() ?? via
  case "--port": port = arguments.next().flatMap(UInt16.init) ?? port
  case "--host": host = arguments.next()
  case "--system-proxy": useSystemProxy = true
  default:
    print(usage)
    exit(argument == "--help" || argument == "-h" ? 0 : 64)
  }
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("nothering: \(message)\n".utf8))
  exit(1)
}

let remotePort: UInt16 = 11080
let connectUpstream: () throws -> Int32
var keepaliveTarget: String?

if via == "usb" || (via == "auto" && host == nil), let deviceID = try? USBMux.firstUSBDeviceID() {
  via = "usb"
  connectUpstream = { try USBMux.connect(deviceID: deviceID, port: remotePort) }
} else if via == "usb" {
  fail("no iPhone connected over USB")
} else {
  via = "hotspot"
  let phone: String
  do {
    phone = try host ?? Hotspot.gatewayAddress()
  } catch {
    fail(error.localizedDescription)
  }
  keepaliveTarget = phone
  connectUpstream = { try Hotspot.connect(host: phone, port: remotePort) }
}

do {
  Darwin.close(try connectUpstream())
} catch {
  fail("cannot reach Nothering on the iPhone via \(via): \(error.localizedDescription)")
}

let forwarder = LocalForwarder(port: port, connectUpstream: connectUpstream)
do {
  port = try forwarder.start()
} catch {
  fail("cannot listen on 127.0.0.1:\(port): \(error.localizedDescription)")
}
print("nothering: 127.0.0.1:\(port) -> iPhone via \(via)")

var systemProxy: SystemProxy?
if useSystemProxy {
  do {
    let proxy = try SystemProxy()
    try proxy.enable(port: port)
    systemProxy = proxy
    print("nothering: system SOCKS proxy enabled on \(proxy.services.joined(separator: ", "))")
  } catch {
    fail("cannot set system proxy: \(error.localizedDescription)")
  }
}

var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
  signal(signalNumber, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler {
    systemProxy?.restore()
    forwarder.stop()
    print("\nnothering: stopped\(systemProxy == nil ? "" : ", system proxy restored")")
    exit(0)
  }
  source.resume()
  signalSources.append(source)
}

// iOS drops idle hotspot clients while the phone is locked; periodic connects keep the link busy.
var keepalive: DispatchSourceTimer?
if let keepaliveTarget {
  let timer = DispatchSource.makeTimerSource(queue: .global())
  timer.schedule(deadline: .now() + 10, repeating: 10)
  timer.setEventHandler {
    do {
      Darwin.close(try Hotspot.connect(host: keepaliveTarget, port: remotePort))
    } catch {
      FileHandle.standardError.write(Data("nothering: keepalive failed: \(error.localizedDescription)\n".utf8))
    }
  }
  timer.resume()
  keepalive = timer
}

dispatchMain()
