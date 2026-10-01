import ProjectDescription

let teamID = "N2C267LBVY"
let bundleIDPrefix = "app.nothering"

let baseSettings: SettingsDictionary = [
  "DEVELOPMENT_TEAM": .string(teamID),
  "CODE_SIGN_STYLE": "Automatic",
  "SWIFT_VERSION": "5.0",
]

let version: [String: Plist.Value] = [
  "CFBundleShortVersionString": "0.1.0",
  "CFBundleVersion": .string(Environment.buildNumber.getString(default: "1")),
]

let hardenedRuntime: SettingsDictionary = ["ENABLE_HARDENED_RUNTIME": "YES"]

// Static frameworks are linked into the apps and never signed on their own.
let unsigned: SettingsDictionary = ["CODE_SIGNING_ALLOWED": "NO"]

let localNetworkUsage: [String: Plist.Value] = [
  "NSLocalNetworkUsageDescription": "Nothering accepts proxy connections from devices on your Personal Hotspot.",
]

// Sparkle reads the newest release's appcast.xml, attached to every GitHub Release by fastlane.
let sparkle: [String: Plist.Value] = [
  "SUFeedURL": "https://github.com/devxoul/nothering/releases/latest/download/appcast.xml",
  "SUPublicEDKey": "Ks/eJWVB8/QBEaOubJWsIiTag+a2oDyxScuqZIcSrV8=",
  "SUEnableAutomaticChecks": true,
]

let project = Project(
  name: "Nothering",
  packages: [
    .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .upToNextMajor(from: "2.10.0")),
  ],
  settings: .settings(base: baseSettings),
  targets: [
    .target(
      name: "ProxyCore",
      destinations: [.iPhone, .mac],
      product: .staticFramework,
      bundleId: "\(bundleIDPrefix).proxycore",
      deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
      sources: ["ProxyCore/Sources/**"],
      settings: .settings(base: unsigned)
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
      bundleId: "\(bundleIDPrefix).ios",
      deploymentTargets: .iOS("18.0"),
      infoPlist: .extendingDefault(with: version.merging(localNetworkUsage) { $1 }.merging([
        "CFBundleDisplayName": "Nothering",
        "UILaunchScreen": [:],
        "UIBackgroundModes": ["audio"],
        "ITSAppUsesNonExemptEncryption": false,
      ]) { $1 }),
      sources: ["iOS/App/**"],
      resources: ["Shared/AppIcon.icon", "iOS/Resources/**"],
      dependencies: [.target(name: "ProxyCore")]
    ),
    .target(
      name: "PhoneLink",
      destinations: [.mac],
      product: .staticFramework,
      bundleId: "\(bundleIDPrefix).phonelink",
      deploymentTargets: .macOS("15.0"),
      sources: ["PhoneLink/Sources/**"],
      settings: .settings(base: unsigned)
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
      bundleId: "\(bundleIDPrefix).cli",
      deploymentTargets: .macOS("15.0"),
      infoPlist: .extendingDefault(with: version),
      sources: ["Mac/Sources/**"],
      dependencies: [.target(name: "ProxyCore"), .target(name: "PhoneLink")],
      settings: .settings(base: hardenedRuntime)
    ),
    .target(
      name: "NotheringMenuBar",
      destinations: [.mac],
      product: .app,
      productName: "Nothering",
      bundleId: "\(bundleIDPrefix).mac",
      deploymentTargets: .macOS("15.0"),
      infoPlist: .extendingDefault(with: version.merging([
        "CFBundleDisplayName": "Nothering",
        "LSUIElement": true,
        "CFBundleURLTypes": [["CFBundleURLName": "app.nothering.mac", "CFBundleURLSchemes": ["nothering"]]],
      ]) { $1 }.merging(sparkle) { $1 }),
      sources: ["MacApp/Sources/**"],
      resources: ["MacApp/Resources/**", "Shared/AppIcon.icon"],
      entitlements: "MacApp/App.entitlements",
      dependencies: [
        .target(name: "NotheringProxyExtension"),
        .target(name: "ProxyCore"),
        .target(name: "PhoneLink"),
        .package(product: "Sparkle"),
      ],
      settings: .settings(base: hardenedRuntime.merging(["CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development"]) { $1 })
    ),
    .target(
      name: "NotheringProxyExtension",
      destinations: [.mac],
      product: .systemExtension,
      productName: "\(bundleIDPrefix).mac.proxy",
      bundleId: "\(bundleIDPrefix).mac.proxy",
      deploymentTargets: .macOS("15.0"),
      infoPlist: .extendingDefault(with: version.merging([
        "NSSystemExtensionUsageDescription": "Nothering routes your Mac's network connections through your iPhone.",
        "NetworkExtension": [
          "NEMachServiceName": "$(TeamIdentifierPrefix)app.nothering.mac.proxy",
          "NEProviderClasses": [
            "com.apple.networkextension.app-proxy": "$(PRODUCT_MODULE_NAME).TransparentProxyProvider",
            "com.apple.networkextension.dns-proxy": "$(PRODUCT_MODULE_NAME).DNSProxyProvider",
          ],
        ],
      ]) { $1 }),
      sources: ["MacProxy/Sources/**"],
      entitlements: "MacProxy/Proxy.entitlements",
      scripts: [
        .post(
          script: #"/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%s)" "$TARGET_BUILD_DIR/$INFOPLIST_PATH""#,
          name: "Stamp Build Version",
          basedOnDependencyAnalysis: false
        ),
      ],
      dependencies: [.target(name: "PhoneLink"), .target(name: "ProxyCore")],
      settings: .settings(base: hardenedRuntime.merging([
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "PRODUCT_MODULE_NAME": "NotheringProxyExtension",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
      ]) { $1 })
    ),
  ]
)
