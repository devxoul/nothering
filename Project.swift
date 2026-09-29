import ProjectDescription

let teamID = "N2C267LBVY"
let bundleIDPrefix = "com.suyeol.nothering"

let baseSettings: SettingsDictionary = [
  "DEVELOPMENT_TEAM": .string(teamID),
  "CODE_SIGN_STYLE": "Automatic",
  "SWIFT_VERSION": "5.0",
]

let localNetworkUsage: [String: Plist.Value] = [
  "NSLocalNetworkUsageDescription": "Nothering accepts proxy connections from devices on your Personal Hotspot.",
]

let project = Project(
  name: "Nothering",
  settings: .settings(base: baseSettings),
  targets: [
    .target(
      name: "ProxyCore",
      destinations: [.iPhone, .mac],
      product: .staticFramework,
      bundleId: "\(bundleIDPrefix).proxycore",
      deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
      sources: ["ProxyCore/Sources/**"]
    ),
    .target(
      name: "ProxyCoreTests",
      destinations: [.mac],
      product: .unitTests,
      bundleId: "\(bundleIDPrefix).proxycore.tests",
      deploymentTargets: .macOS("15.0"),
      sources: ["ProxyCore/Tests/**"],
      dependencies: [.target(name: "ProxyCore")]
    ),
    .target(
      name: "NotheringiOS",
      destinations: [.iPhone],
      product: .app,
      productName: "Nothering",
      bundleId: bundleIDPrefix,
      deploymentTargets: .iOS("18.0"),
      infoPlist: .extendingDefault(with: localNetworkUsage.merging([
        "CFBundleDisplayName": "Nothering",
        "UILaunchScreen": [:],
        "UIBackgroundModes": ["audio"],
      ]) { $1 }),
      sources: ["iOS/App/**"],
      entitlements: "iOS/App.entitlements",
      dependencies: [.target(name: "NotheringTunnel"), .target(name: "ProxyCore")]
    ),
    .target(
      name: "NotheringTunnel",
      destinations: [.iPhone],
      product: .appExtension,
      bundleId: "\(bundleIDPrefix).tunnel",
      deploymentTargets: .iOS("18.0"),
      infoPlist: .extendingDefault(with: localNetworkUsage.merging([
        "CFBundleDisplayName": "Nothering Tunnel",
        "NSExtension": [
          "NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel",
          "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).PacketTunnelProvider",
        ],
      ]) { $1 }),
      sources: ["iOS/Tunnel/**"],
      entitlements: "iOS/Tunnel.entitlements",
      dependencies: [.target(name: "ProxyCore")]
    ),
  ]
)
