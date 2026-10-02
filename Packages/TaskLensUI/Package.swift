// swift-tools-version: 6.0
import PackageDescription

// TaskLensUI holds SwiftUI code: localization, design system, navigation and
// one module per feature. Features depend on TaskLensKit services, never on
// each other, and never on concrete persistence.
let package = Package(
    name: "TaskLensUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "TLLocalization", targets: ["TLLocalization"]),
        .library(name: "TLDesignSystem", targets: ["TLDesignSystem"]),
        .library(name: "TLNavigation", targets: ["TLNavigation"]),
        .library(name: "CommandCenterFeature", targets: ["CommandCenterFeature"]),
        .library(name: "WorkspacesFeature", targets: ["WorkspacesFeature"]),
        .library(name: "SessionsFeature", targets: ["SessionsFeature"]),
        .library(name: "SettingsFeature", targets: ["SettingsFeature"]),
        .library(name: "LensFeature", targets: ["LensFeature"]),
        .library(name: "ClipboardFeature", targets: ["ClipboardFeature"]),
    ],
    dependencies: [
        .package(path: "../TaskLensKit"),
    ],
    targets: [
        .target(
            name: "TLLocalization",
            dependencies: [
                .product(name: "TLFoundation", package: "TaskLensKit"),
                .product(name: "TLDomain", package: "TaskLensKit"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "TLDesignSystem",
            dependencies: [
                "TLLocalization",
                .product(name: "TLDomain", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "TLNavigation",
            dependencies: [
                .product(name: "TLDomain", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "CommandCenterFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem", "TLNavigation",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "WorkspacesFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem", "TLNavigation",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "SessionsFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem", "TLNavigation",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "SettingsFeature",
            dependencies: ["TLLocalization", "TLDesignSystem"]
        ),
        .target(
            name: "LensFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "ClipboardFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .testTarget(
            name: "TaskLensUITests",
            dependencies: [
                "TLLocalization", "TLNavigation", "CommandCenterFeature", "WorkspacesFeature", "SessionsFeature",
                "LensFeature", "ClipboardFeature",
                .product(name: "TLFoundation", package: "TaskLensKit"),
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLData", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
