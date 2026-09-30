import ProjectDescription

let teamID = "N2C267LBVY"
let bundleIDPrefix = "app.nothering"

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
      bundleId: "\(bundleIDPrefix).ios",
      deploymentTargets: .iOS("18.0"),
      infoPlist: .extendingDefault(with: localNetworkUsage.merging([
        "CFBundleDisplayName": "Nothering",
        "UILaunchScreen": [:],
        "UIBackgroundModes": ["audio"],
      ]) { $1 }),
      sources: ["iOS/App/**"],
      resources: ["Shared/AppIcon.icon"],
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
      bundleId: "\(bundleIDPrefix).cli",
      deploymentTargets: .macOS("15.0"),
      sources: ["Mac/Sources/**"],
      dependencies: [.target(name: "ProxyCore"), .target(name: "PhoneLink")]
    ),
    .target(
      name: "NotheringMenuBar",
      destinations: [.mac],
      product: .app,
      productName: "Nothering",
      bundleId: "\(bundleIDPrefix).mac",
      deploymentTargets: .macOS("15.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "Nothering",
        "LSUIElement": true,
        "CFBundleURLTypes": [["CFBundleURLName": "app.nothering.mac", "CFBundleURLSchemes": ["nothering"]]],
      ]),
      sources: ["MacApp/Sources/**"],
      resources: ["MacApp/Resources/**", "Shared/AppIcon.icon"],
      entitlements: "MacApp/App.entitlements",
      dependencies: [
        .target(name: "NotheringProxyExtension"),
        .target(name: "ProxyCore"),
        .target(name: "PhoneLink"),
      ],
      settings: .settings(base: ["CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development"])
    ),
    .target(
      name: "NotheringProxyExtension",
      destinations: [.mac],
      product: .systemExtension,
      productName: "\(bundleIDPrefix).mac.proxy",
      bundleId: "\(bundleIDPrefix).mac.proxy",
      deploymentTargets: .macOS("15.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "NSSystemExtensionUsageDescription": "Nothering routes your Mac's network connections through your iPhone.",
        "NetworkExtension": [
          "NEMachServiceName": "$(TeamIdentifierPrefix)app.nothering.mac.proxy",
          "NEProviderClasses": [
            "com.apple.networkextension.app-proxy": "$(PRODUCT_MODULE_NAME).TransparentProxyProvider",
            "com.apple.networkextension.dns-proxy": "$(PRODUCT_MODULE_NAME).DNSProxyProvider",
          ],
        ],
      ]),
      sources: ["MacProxy/Sources/**"],
      entitlements: "MacProxy/Proxy.entitlements",
      dependencies: [.target(name: "PhoneLink"), .target(name: "ProxyCore")],
      settings: .settings(base: [
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "PRODUCT_MODULE_NAME": "NotheringProxyExtension",
      ])
    ),
  ]
)
