// swift-tools-version:5.9
import PackageDescription

// Linux and Windows have no CoreGraphics module (Foundation carries CGPoint, CGFloat and CGSize), so a stand-in
// that re-exports Foundation lets `import CoreGraphics` in the core and its tests resolve. macOS uses the real one.
#if os(Linux) || os(Windows)
let coreGraphicsStandIn: [Target.Dependency] = ["CoreGraphics"]
// Vision is Apple-only too, so the fixture replay helper and the two test files that call it are left out there.
// CryptoKit is Apple-only as well: the usage checksum, the usage summary and the request body sit behind
// canImport(CryptoKit), so UsageSummaryTests imports it and UsageTrackerTests calls the request body, and both are
// left out there (which also drops the usage-counter tests in UsageTrackerTests).
// PointingClassifierTests builds a Hand and calls the gesture classifier, which sit behind canImport(Vision).
// WidthGesturesTests builds a Hand and calls the gesture classifier and its adapter, which sit behind canImport(Vision).
let testsNeedingAppleFrameworks = [
    "FixtureReplay.swift", "FixtureTests.swift", "PeaceRecognitionTests.swift",
    "UsageSummaryTests.swift", "UsageTrackerTests.swift",
    "PointingClassifierTests.swift", "WidthGesturesTests.swift",
]
#else
let coreGraphicsStandIn: [Target.Dependency] = []
let testsNeedingAppleFrameworks: [String] = []
#endif

let package = Package(
    name: "Ensemble",
    platforms: [.macOS(.v14)],
    // EnsembleCore as a library only so Tools/PerfBench can replay the pointer pipeline; the app links the target.
    products: [.library(name: "EnsembleCore", targets: ["EnsembleCore"])],
    targets: [
        // Pure logic: gesture rules, gesture state machine, nose pointer. No camera, no UI, unit-tested.
        .target(name: "EnsembleCore", dependencies: coreGraphicsStandIn, path: "Sources/EnsembleCore", exclude: ["Vendor/Sleight/LICENSE-sleight", "Vendor/LICENSE-claude-dictation-hotkey"]),
        .testTarget(name: "EnsembleCoreTests", dependencies: ["EnsembleCore"] + coreGraphicsStandIn, path: "Tests/EnsembleCoreTests", exclude: testsNeedingAppleFrameworks, resources: [.copy("Fixtures")]),
    ]
)

#if os(Linux) || os(Windows)
package.targets.append(.target(name: "CoreGraphics", path: "Sources/CoreGraphicsStandIn"))
#endif

// The menu-bar app and Sparkle are AppKit-only, so they are declared on macOS alone: off Apple a plain `swift test`
// then builds just the core and its tests.
#if os(macOS)
package.dependencies.append(
    // Auto-updates. Pinned exactly; bump deliberately (see docs/RELEASING.md).
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
)
package.targets.append(
    .executableTarget(
        name: "Ensemble",
        dependencies: ["EnsembleCore", .product(name: "Sparkle", package: "Sparkle")],
        path: "Sources/Ensemble",
        // The web folder is copied by scripts/bundle.sh, not declared as a SwiftPM resource: SwiftPM's generated
        // resource accessor embeds the build machine's absolute path (its home folder and user name) in the binary.
        exclude: ["Info.plist", "Ensemble.entitlements", "Resources"],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/Ensemble/Info.plist",
                // scripts/bundle.sh embeds Sparkle.framework in Contents/Frameworks.
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            ])
        ]
    )
)
#endif
