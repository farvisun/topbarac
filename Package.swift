// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Topbarac",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Topbarac", targets: ["Topbarac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "TopbaracCore",
            path: "Sources/TopbaracCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "Topbarac",
            dependencies: ["TopbaracCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Topbarac",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Charts"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
        .testTarget(
            name: "TopbaracCoreTests",
            dependencies: ["TopbaracCore"],
            path: "Tests/TopbaracCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
