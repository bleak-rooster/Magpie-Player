// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MagpieKit",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "MagpieCore", targets: ["MagpieCore"]),
        .library(name: "NavidromeKit", targets: ["NavidromeKit"]),
        .library(name: "ListenBrainzKit", targets: ["ListenBrainzKit"]),
        .library(name: "LidarrKit", targets: ["LidarrKit"]),
        .library(name: "AurralKit", targets: ["AurralKit"]),
        .library(name: "MatchIndex", targets: ["MatchIndex"]),
        .library(name: "Search", targets: ["Search"]),
        .library(name: "Requests", targets: ["Requests"]),
        .library(name: "Playback", targets: ["Playback"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "CarPlayUI", targets: ["CarPlayUI"]),
        .library(name: "MagpieTestSupport", targets: ["MagpieTestSupport"]),
    ],
    targets: [
        .target(name: "MagpieCore"),
        .target(name: "NavidromeKit", dependencies: ["MagpieCore"]),
        .target(name: "ListenBrainzKit", dependencies: ["MagpieCore"]),
        .target(name: "LidarrKit", dependencies: ["MagpieCore"]),
        // Round 12 Y6: Aurral (Discover). Its own module: an allow-listed client, and the pure Discover rules.
        .target(name: "AurralKit", dependencies: ["MagpieCore"]),
        .target(name: "MatchIndex", dependencies: ["MagpieCore", "NavidromeKit"]),
        .target(name: "Search", dependencies: ["MagpieCore", "MatchIndex", "ListenBrainzKit", "LidarrKit", "AurralKit"]),
        .target(name: "Requests", dependencies: ["MagpieCore", "LidarrKit", "ListenBrainzKit", "NavidromeKit", "MatchIndex"]),
        // Round 14 A7: the preview engine plays the bytes Aurral sent (AurralKit's `PreviewResolver` fetches them).
        .target(name: "Playback", dependencies: ["MagpieCore"]),
        .target(name: "DesignSystem", dependencies: ["MagpieCore"]),
        .target(name: "CarPlayUI", dependencies: ["MagpieCore", "Playback", "DesignSystem", "Search"]),
        .target(name: "MagpieTestSupport", dependencies: ["MagpieCore", "AurralKit"]),
        .testTarget(name: "MagpieCoreTests", dependencies: ["MagpieCore", "MagpieTestSupport"]),
        .testTarget(name: "NavidromeKitTests",
                    dependencies: ["NavidromeKit", "MagpieCore", "MagpieTestSupport"],
                    resources: [.copy("../Fixtures/navidrome")]),
        .testTarget(name: "LidarrKitTests",
                    dependencies: ["LidarrKit", "MagpieCore", "MagpieTestSupport"],
                    resources: [.copy("../Fixtures/lidarr")]),
        .testTarget(name: "ListenBrainzKitTests",
                    dependencies: ["ListenBrainzKit", "MagpieCore", "MagpieTestSupport"],
                    resources: [.copy("../Fixtures/listenbrainz"), .copy("../Fixtures/musicbrainz")]),
        .testTarget(name: "AurralKitTests", dependencies: ["AurralKit", "MagpieCore", "MagpieTestSupport"]),
        .testTarget(name: "PlaybackTests", dependencies: ["Playback", "MagpieCore", "MagpieTestSupport"]),
        .testTarget(name: "MatchIndexTests", dependencies: ["MatchIndex", "MagpieCore", "NavidromeKit", "MagpieTestSupport"]),
        .testTarget(name: "RequestsTests",
                    dependencies: ["Requests", "MagpieCore", "LidarrKit", "ListenBrainzKit", "NavidromeKit", "MagpieTestSupport"]),
        // Crash hunt 4: seeded fuzzing of every client's decoding, and the decoded models through the UI and car builders.
        .testTarget(name: "HostileDataTests",
                    dependencies: ["NavidromeKit", "LidarrKit", "ListenBrainzKit", "MatchIndex", "Search", "CarPlayUI",
                                   "Playback", "Requests", "MagpieCore", "MagpieTestSupport"],
                    resources: [.copy("../Fixtures/navidrome"), .copy("../Fixtures/lidarr"),
                                .copy("../Fixtures/listenbrainz"), .copy("../Fixtures/musicbrainz")]),
        // Y2: the car's A–Z lists (pure models; run on macOS like the other package suites).
        .testTarget(name: "CarPlayUITests", dependencies: ["CarPlayUI", "MagpieCore", "Search"]),
        .testTarget(name: "SearchTests",
                    dependencies: ["Search", "MatchIndex", "MagpieCore", "LidarrKit", "ListenBrainzKit", "AurralKit", "MagpieTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
