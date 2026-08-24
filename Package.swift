// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Voorsorteren",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Voorsorteren",
            path: "Sources/Voorsorteren",
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
