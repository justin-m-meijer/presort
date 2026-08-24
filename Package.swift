// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Presort",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Presort",
            path: "Sources/Presort",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
