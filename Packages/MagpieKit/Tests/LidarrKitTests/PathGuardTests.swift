import Testing
@testable import LidarrKit

/// Review focus 5 / G2 / G3.3 / G9: path confinement for the Finds root.
struct PathGuardTests {
    let guardSamples = PathGuard(findsRoot: "/music/samples", otherRoots: ["/music/library"], caseInsensitive: false)

    @Test func insideAcceptsFilesUnderTheRoot() {
        #expect(guardSamples.isInside("/music/samples/Artist/Album/01 Song.flac"))
        #expect(guardSamples.isInside("/music/samples/Artist"))
    }

    @Test func rootItselfIsNotInside() {
        // Deleting the Finds folder itself is never "a file Magpie brought in".
        #expect(!guardSamples.isInside("/music/samples"))
        #expect(!guardSamples.isInside("/music/samples/"))
        #expect(!guardSamples.isInside("/music/samples/."))
    }

    @Test func siblingPrefixRejected() {
        // A bare hasPrefix lets these through (G3.3).
        #expect(!guardSamples.isInside("/music/samples-old/x"))
        #expect(!guardSamples.isInside("/music/samplesx/Artist/x.flac"))
        #expect(!guardSamples.isInside("/music/sample/x"))
    }

    @Test func dotDotRejected() {
        #expect(!guardSamples.isInside("/music/samples/../library/Artist/x.flac"))
        #expect(!guardSamples.isInside("/music/samples/Artist/../../library/x"))
        #expect(!guardSamples.isInside("/music/samples/.."))
        #expect(!guardSamples.isInside("/../../music/samples-old/x"))
        // `..` that stays inside is resolved, not refused.
        #expect(guardSamples.isInside("/music/samples/Artist/../Other/x.flac"))
        // `..` above `/` stays at `/`, as on a real filesystem.
        #expect(guardSamples.isInside("/../music/samples/Artist/x.flac"))
    }

    @Test func trailingSlashOK() {
        let g = PathGuard(findsRoot: "/music/samples/", otherRoots: ["/music/library/"], caseInsensitive: false)
        #expect(g.isInside("/music/samples/Artist/"))
        #expect(g.isInside("/music/samples//Artist//x.flac"))
        #expect(!g.isInside("/music/samples-old/"))
        #expect(PathGuard.validateRoot("/music/samples/", others: ["/music/samples"]) == .equalsOther)
    }

    @Test func nestedRootRejected() {
        #expect(PathGuard.validateRoot("/music/library/samples", others: ["/music/library"]) == .nested)
        #expect(PathGuard.validateRoot("/music", others: ["/music/library"]) == .nested)
        #expect(PathGuard.validateRoot("/", others: ["/music/library"]) == .nested)
        #expect(PathGuard.validateRoot("/music/samples", others: ["/music/library"]) == .ok)
        #expect(PathGuard.validateRoot("/music/samples-old", others: ["/music/samples"]) == .ok, "siblings are not nested")
        // A guard built on a nested root refuses everything (defence in depth: confirmation should have stopped it).
        let nested = PathGuard(findsRoot: "/music/library/samples", otherRoots: ["/music/library"], caseInsensitive: false)
        #expect(!nested.isInside("/music/library/samples/Artist/x.flac"))
    }

    @Test func equalRootRejected() {
        #expect(PathGuard.validateRoot("/music/library", others: ["/music/library"]) == .equalsOther)
        #expect(PathGuard.validateRoot("/music/./library", others: ["/music/library/"]) == .equalsOther)
        // Equal ignoring case is refused too: the server's filesystem may not tell them apart.
        #expect(PathGuard.validateRoot("/Music/Library", others: ["/music/library"]) == .equalsOther)
        #expect(PathGuard.validateRoot("/Music/Library/Samples", others: ["/music/library"]) == .nested)
        let equal = PathGuard(findsRoot: "/music/library", otherRoots: ["/music/library"], caseInsensitive: false)
        #expect(!equal.isInside("/music/library/Artist/x.flac"))
    }

    @Test func notAbsoluteRejected() {
        #expect(PathGuard.validateRoot("", others: []) == .notAbsolute)
        #expect(PathGuard.validateRoot("music/samples", others: []) == .notAbsolute)
        #expect(PathGuard.validateRoot(#"C:\Music\Samples"#, others: []) == .notAbsolute)
        #expect(!guardSamples.isInside("samples/Artist/x.flac"))
        #expect(!guardSamples.isInside(""))
    }

    @Test func caseSensitivity() {
        // Case-sensitive volume (the default): another spelling is another folder.
        #expect(!guardSamples.isInside("/Music/Samples/Artist/x.flac"))
        #expect(!guardSamples.isInside("/music/SAMPLES/Artist/x.flac"))
        // Case-insensitive volume: the same folder.
        let ci = PathGuard(findsRoot: "/Music/Samples", otherRoots: ["/Music/Library"], caseInsensitive: true)
        #expect(ci.isInside("/music/samples/Artist/x.flac"))
        #expect(!ci.isInside("/music/samples-old/x.flac"))
        #expect(!ci.isInside("/MUSIC/LIBRARY/Artist/x.flac"))
    }

    /// PathGuard compares the strings Lidarr reports; it can't see the server's filesystem or follow links.
    /// What it does guarantee: a path only passes when, after standardising, it lies under the confirmed
    /// root's own spelling and inside no other root. So a link resolved by Lidarr (reported under its target)
    /// is refused, and a root that only reaches another root through dot segments is refused.
    @Test func symlinkedRootRejected() {
        // /music/samples is a link to /music/library/samples; Lidarr reports the resolved path.
        #expect(!guardSamples.isInside("/music/library/samples/Artist/x.flac"))
        // A root spelled so that it lands inside the library after standardising.
        #expect(PathGuard.validateRoot("/music/samples/../library/finds", others: ["/music/library"]) == .nested)
        #expect(PathGuard.validateRoot("/music/library/./", others: ["/music/library"]) == .equalsOther)
        // Another root nested inside the Finds root (a link target folded back in): files there are refused
        // even if confirmation was bypassed.
        let g = PathGuard(findsRoot: "/music/samples", otherRoots: ["/music/samples/library"], caseInsensitive: false)
        #expect(!g.isInside("/music/samples/library/Artist/x.flac"))
        #expect(!g.isInside("/music/samples/Artist/x.flac"), "an invalid guard refuses everything")
    }
}

/// B6: Lidarr and Navidrome may mount the same folder at different paths.
struct PathMappingTests {
    @Test func mapsPrefix() {
        let m = PathMapping(lidarrPrefix: "/data/music", navidromePrefix: "/music")
        #expect(m.toNavidrome("/data/music/samples/Artist/x.flac") == "/music/samples/Artist/x.flac")
        #expect(m.toNavidrome("/data/music/samples/") == "/music/samples")
        #expect(m.toNavidrome("/data/music") == "/music")
        #expect(m.toNavidrome("/data/music-old/samples") == nil, "component boundary, not a bare prefix")
        #expect(m.toNavidrome("/data/music/../other/x") == nil, "`..` can't climb out of the prefix")
        #expect(m.toNavidrome("/elsewhere/x") == nil)
        #expect(m.toNavidrome("relative/x") == nil)
    }

    @Test func trailingSlashesAndRootPrefix() {
        let m = PathMapping(lidarrPrefix: "/data/music/", navidromePrefix: "/music/")
        #expect(m.toNavidrome("/data/music/samples") == "/music/samples")
        let toRoot = PathMapping(lidarrPrefix: "/data", navidromePrefix: "/")
        #expect(toRoot.toNavidrome("/data/samples") == "/samples")
        let fromRoot = PathMapping(lidarrPrefix: "/", navidromePrefix: "/mnt")
        #expect(fromRoot.toNavidrome("/samples/x") == "/mnt/samples/x")
    }

    @Test func invalidPrefixMapsNothing() {
        #expect(PathMapping(lidarrPrefix: "data", navidromePrefix: "/music").toNavidrome("/data/x") == nil)
        #expect(PathMapping(lidarrPrefix: "/data", navidromePrefix: "").toNavidrome("/data/x") == nil)
    }
}
