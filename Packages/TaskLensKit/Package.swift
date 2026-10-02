// swift-tools-version: 6.0
import PackageDescription

// TaskLensKit holds everything that does not depend on UI frameworks:
// foundation utilities, the domain model, persistence and core services.
// It builds for macOS as well so its tests can run quickly on a Mac host.
let package = Package(
    name: "TaskLensKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TLFoundation", targets: ["TLFoundation"]),
        .library(name: "TLDomain", targets: ["TLDomain"]),
        .library(name: "TLData", targets: ["TLData"]),
        .library(name: "TLCoreServices", targets: ["TLCoreServices"]),
    ],
    targets: [
        .target(name: "TLFoundation"),
        .target(name: "TLDomain", dependencies: ["TLFoundation"]),
        .target(name: "TLData", dependencies: ["TLFoundation", "TLDomain"]),
        .target(name: "TLCoreServices", dependencies: ["TLFoundation", "TLDomain"]),

        .testTarget(name: "TLFoundationTests", dependencies: ["TLFoundation"]),
        .testTarget(name: "TLDomainTests", dependencies: ["TLFoundation", "TLDomain"]),
        .testTarget(name: "TLDataTests", dependencies: ["TLFoundation", "TLDomain", "TLData"]),
        .testTarget(
            name: "TLCoreServicesTests",
            dependencies: ["TLFoundation", "TLDomain", "TLData", "TLCoreServices"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
