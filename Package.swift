// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Presort",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Presort",
            path: "Sources/Presort",
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
