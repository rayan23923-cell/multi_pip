// swift-tools-version: 6.0
import PackageDescription

// TaskLensUI holds SwiftUI code: localization, design system, navigation and
// one module per feature (each tool is its own feature module). Features depend on TaskLensKit services, never on
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
        .library(name: "NotesFeature", targets: ["NotesFeature"]),
        .library(name: "CalculatorFeature", targets: ["CalculatorFeature"]),
        .library(name: "BrowserFeature", targets: ["BrowserFeature"]),
        .library(name: "DocumentsFeature", targets: ["DocumentsFeature"]),
        .library(name: "ImageViewerFeature", targets: ["ImageViewerFeature"]),
        .library(name: "TextViewerFeature", targets: ["TextViewerFeature"]),
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
        .target(
            name: "NotesFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem", "TLNavigation",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "CalculatorFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem", "TLNavigation",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "BrowserFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem", "TLNavigation",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "DocumentsFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem", "TLNavigation",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "ImageViewerFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem", "TLNavigation",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .target(
            name: "TextViewerFeature",
            dependencies: [
                "TLLocalization", "TLDesignSystem", "TLNavigation",
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
        .testTarget(
            name: "TaskLensUITests",
            dependencies: [
                "TLLocalization", "TLNavigation", "CommandCenterFeature", "WorkspacesFeature", "SessionsFeature",
                "LensFeature", "ClipboardFeature",
                "NotesFeature", "CalculatorFeature", "BrowserFeature", "DocumentsFeature",
                "ImageViewerFeature", "TextViewerFeature",
                .product(name: "TLFoundation", package: "TaskLensKit"),
                .product(name: "TLDomain", package: "TaskLensKit"),
                .product(name: "TLData", package: "TaskLensKit"),
                .product(name: "TLCoreServices", package: "TaskLensKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
