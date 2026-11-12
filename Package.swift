// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FinderMinder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FinderMinder",
            path: "Sources/FinderMinder",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
