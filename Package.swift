// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Notification",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Notification", targets: ["NotificationApp"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "NotificationCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "NotificationApp", dependencies: ["NotificationCore"]),
        // Executable checks also run with Command Line Tools, without the XCTest framework from Xcode.
        .executableTarget(name: "NotificationCoreTests", dependencies: ["NotificationCore", "CSQLite"], path: "Tests/NotificationCoreTests")
    ]
)
