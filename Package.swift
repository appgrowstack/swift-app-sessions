// swift-tools-version: 6.2
import PackageDescription

/// What people do inside an app, session by session: where a session starts and ends, which
/// screens they went through and how, where they tapped, where they tapped in anger or for nothing,
/// how quickly they went back, how far they scrolled, when the app stopped answering, and how the
/// session ended. The app chooses where the records go (`SessionSink`).
///
/// **No external dependencies.** Analytics events are handed over as a name and values.
let package = Package(
    name: "swift-app-sessions",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // Splitting sessions, the rules (rage, dead, quick back, end reason, scroll depth, tap
        // position, sampling, kept props), the recorder, batches, the sink port and the two
        // standalone sinks (a file and a debug log). Foundation and Observation only.
        .library(name: "SessionsCore", targets: ["SessionsCore"]),
        // UIKit: taps, the app's lifecycle, the keyboard, scroll views, hangs, MetricKit crashes
        // and the device's values. Compiles to nothing outside UIKit.
        .library(name: "SessionsCapture", targets: ["SessionsCapture"]),
        // SwiftUI marks: `.sessionTarget`, `.sessionScroll`, `.sessionMask`, `.sessionNoCapture`.
        .library(name: "SessionsSwiftUI", targets: ["SessionsSwiftUI"]),
        // Test doubles: a clock, a state store, id generator and a recording sink.
        .library(name: "SessionsTesting", targets: ["SessionsTesting"])
    ],
    targets: [
        .target(name: "SessionsCore"),
        .target(name: "SessionsCapture", dependencies: ["SessionsCore"]),
        .target(name: "SessionsSwiftUI", dependencies: ["SessionsCore", "SessionsCapture"]),
        .target(name: "SessionsTesting", dependencies: ["SessionsCore"]),

        .testTarget(
            name: "SessionsCoreTests",
            dependencies: ["SessionsCore", "SessionsTesting"],
            resources: [.copy("Cases")]
        )
    ]
)
