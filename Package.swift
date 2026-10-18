// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ATVRemoteKit",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "ATVRemoteKit", targets: ["ATVRemoteKit"]),
    ],
    targets: [
        .target(name: "ATVRemoteKit"),
        // macOS CLI used to prove the protocol against the real TV without Xcode/Simulator.
        .executableTarget(name: "atvctl", dependencies: ["ATVRemoteKit"]),
        // macOS menu-bar widget; bundled into TVRemoteBar.app by scripts/build-mac-widget.sh.
        .executableTarget(name: "TVRemoteBar", dependencies: ["ATVRemoteKit"]),
    ]
)
