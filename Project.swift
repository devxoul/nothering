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
      dependencies: [.target(name: "ProxyCore")]
    ),
    .target(
      name: "PhoneLink",
      destinations: [.mac],
      product: .staticFramework,
      bundleId: "\(bundleIDPrefix).phonelink",
      deploymentTargets: .macOS("15.0"),
      sources: ["PhoneLink/Sources/**"]
    ),
    .target(
      name: "PhoneLinkTests",
      destinations: [.mac],
      product: .unitTests,
      bundleId: "\(bundleIDPrefix).phonelink.tests",
      deploymentTargets: .macOS("15.0"),
      sources: ["PhoneLink/Tests/**"],
      dependencies: [.target(name: "PhoneLink"), .target(name: "ProxyCore")]
    ),
    .target(
      name: "NotheringMac",
      destinations: [.mac],
      product: .commandLineTool,
      productName: "nothering",
      bundleId: "\(bundleIDPrefix).mac",
      deploymentTargets: .macOS("15.0"),
      sources: ["Mac/Sources/**"],
      dependencies: [.target(name: "ProxyCore"), .target(name: "PhoneLink")]
    ),
  ]
)
