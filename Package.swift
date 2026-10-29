// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "XM6Connect",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        // Sony MDR protocol layer and the
        // IOBluetooth transport, which started from xm6-control (MIT, see
        // THIRD_PARTY/xm6-control-LICENSE).
        .target(
            name: "SonyHeadphonesKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        ),
        .executableTarget(
            name: "KitTests",
            dependencies: ["SonyHeadphonesKit", "XM6ConnectAgentCore", "XM6ConnectWidgetLogic", "XM6ConnectAppLogic"],
            path: "Tests/KitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "XM6ConnectAgent",
            dependencies: ["XM6ConnectAgentCore"],
            exclude: ["Core", "Info.plist"],
            sources: ["main.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // A launchd binary has no app bundle from which TCC can read this.
                // Embed the same usage string directly in the executable instead.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", "Sources/XM6ConnectAgent/Info.plist"
                ])
            ]
        ),
        // Internal module: keeps the daemon core importable by deterministic KitTests
        // without turning the requested XM6ConnectAgent executable into a library product.
        .target(
            name: "XM6ConnectAgentCore",
            dependencies: ["SonyHeadphonesKit"],
            path: "Sources/XM6ConnectAgent/Core",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Foundation-only widget decisions are kept importable by the CLT test
        // harness.  The WidgetKit entry point is compiled directly by build_app.sh.
        .target(
            name: "XM6ConnectWidgetLogic",
            dependencies: ["SonyHeadphonesKit"],
            path: "Sources/XM6ConnectWidget",
            exclude: ["XM6ConnectDesktopWidget.swift", "Info.plist", "entitlements.plist"],
            sources: ["WidgetLogic.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Foundation-only popover state and IPC logic.  Keeping this separate makes
        // the UI behavior testable without starting AppKit or SwiftUI.
        .target(
            name: "XM6ConnectAppLogic",
            dependencies: ["SonyHeadphonesKit"],
            path: "Sources/XM6ConnectApp",
            exclude: ["XM6ConnectApp.swift", "Info.plist", "entitlements.plist"],
            sources: ["PopoverModel.swift", "AgentLifecycle.swift", "AppDelegate.swift", "PopoverView.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "xm6ctl",
            dependencies: ["XM6ConnectAgentCore", "SonyHeadphonesKit"],
            path: "Sources/XM6ConnectCtl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
