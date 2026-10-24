// swift-tools-version: 6.2
// ASO Workbench: native macOS App Store Optimization workspace.
//
// Layering (compile-time enforced by SwiftPM targets):
//   ASOCore       pure domain: models, provider contracts, validation, analysis. No Foundation networking, no UI.
//   ASOProviders  infrastructure: Apple public search, App Store hints, Apple Ads Platform API v1, App Store Connect.
//   ASOWorkbench     the macOS app: SwiftData persistence, orchestration services, SwiftUI features.
import PackageDescription

let package = Package(
    name: "ASOWorkbench",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ASOWorkbench", targets: ["ASOWorkbench"]),
        .library(name: "ASOCore", targets: ["ASOCore"]),
        .library(name: "ASOProviders", targets: ["ASOProviders"]),
    ],
    targets: [
        .target(
            name: "ASOCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ASOProviders",
            dependencies: ["ASOCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ASOWorkbench",
            dependencies: ["ASOCore", "ASOProviders"],
            path: "Sources/ASOWorkbench",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(name: "ASOCoreTests", dependencies: ["ASOCore"]),
        .testTarget(name: "ASOProvidersTests", dependencies: ["ASOProviders", "ASOCore"]),
    ]
)
