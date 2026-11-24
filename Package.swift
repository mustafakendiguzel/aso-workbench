// swift-tools-version: 6.2
// ASO Workbench: native macOS App Store Optimization workspace.
//
// Layering (compile-time enforced by SwiftPM targets):
//   ASOCore       pure domain: models, provider contracts, validation, analysis. No Foundation networking, no UI.
//   ASOProviders  infrastructure: Apple public search, App Store hints, Apple Ads Platform API v1, App Store Connect.
//   ASOWorkbench  the macOS app: SwiftData persistence, orchestration services, SwiftUI features.
//   ASOEngine     the platform-neutral workbench: an SQLite store (the platform's own SQLite, via CSQLite) and jobs.
//   ASOCommands   the `aso` command line on top of ASOEngine; ASOCLI is its thin executable.
//
// Platforms: the whole package builds on macOS with zero dependencies. Everything but the macOS app also builds on
// Linux and Windows; there CryptoKit is replaced by Apple's API-compatible swift-crypto, and the macOS app target
// is left out. The manifest is evaluated on the build host, so `#if os(macOS)` selects the host's package graph.
import PackageDescription

#if os(macOS)
let platformProducts: [Product] = [.executable(name: "ASOWorkbench", targets: ["ASOWorkbench"])]
let platformDependencies: [Package.Dependency] = []
let cryptoDependencies: [Target.Dependency] = []
let platformTargets: [Target] = [
    .executableTarget(
        name: "ASOWorkbench",
        dependencies: ["ASOCore", "ASOProviders"],
        path: "Sources/ASOWorkbench",
        swiftSettings: [
            .swiftLanguageMode(.v6),
            .defaultIsolation(MainActor.self),
        ]
    ),
]
#else
let platformProducts: [Product] = []
let platformDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
]
let cryptoDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
let platformTargets: [Target] = []
#endif

let package = Package(
    name: "ASOWorkbench",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: platformProducts + [
        .library(name: "ASOCore", targets: ["ASOCore"]),
        .library(name: "ASOProviders", targets: ["ASOProviders"]),
        .library(name: "ASOEngine", targets: ["ASOEngine"]),
        .executable(name: "aso", targets: ["ASOCLI"]),
    ],
    dependencies: platformDependencies,
    targets: platformTargets + [
        .target(
            name: "ASOCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ASOProviders",
            dependencies: ["ASOCore"] + cryptoDependencies,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "ASOEngine",
            dependencies: ["ASOCore", "ASOProviders", "CSQLite"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ASOCommands",
            dependencies: ["ASOCore", "ASOProviders", "ASOEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ASOCLI",
            dependencies: ["ASOCommands"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "ASOCoreTests", dependencies: ["ASOCore"]),
        .testTarget(name: "ASOProvidersTests", dependencies: ["ASOProviders", "ASOCore"] + cryptoDependencies),
        .testTarget(name: "ASOEngineTests", dependencies: ["ASOEngine", "ASOCommands", "ASOCore", "ASOProviders"]),
    ]
)
