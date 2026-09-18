// EnergyTests.swift
// v1.7.1: an iOS CPU resource report (57 % CPU for 2.5 minutes, on battery)
// traced to the whole app re-rendering at 10 Hz and the Albums list regrouping
// ~820 albums on every render. These pin the pieces of the fix that are logic.
import Testing
import Foundation
@testable import mikMPD

@Suite struct DisplayTimerGateTests {
    @Test func runsOnlyWhenPlayingForegroundAndWatched() {
        #expect(displayTimerShouldRun(isPlaying: true, sceneActive: true, observers: 1))
    }

    /// The lock screen extrapolates elapsed itself; nobody sees a background tick.
    @Test func neverInTheBackground() {
        #expect(!displayTimerShouldRun(isPlaying: true, sceneActive: false, observers: 2))
    }

    /// The Library tab shows no time, so it must not pay for a 10 Hz clock.
    @Test func notWithoutAnObservingView() {
        #expect(!displayTimerShouldRun(isPlaying: true, sceneActive: true, observers: 0))
    }

    @Test func notWhilePausedOrStopped() {
        #expect(!displayTimerShouldRun(isPlaying: false, sceneActive: true, observers: 1))
    }
}

@Suite struct AlbumGroupStoredKeyTests {
    @Test func storedKeyMatchesTheFunction() {
        for base in ["1967–1970", "1967-1970", "Quadrophenia [Disc 1]", "  Live At Leeds ",
                     "Don’t Stop…", "“Heroes”", "X [24-bit Remaster CD 1]", ""] {
            #expect(AlbumGroup(artist: "A", base: base, variants: [base]).groupingKey
                    == albumGroupingKey(base), "\(base)")
        }
    }

    @Test func keyFollowsAChangedBase() {
        var g = AlbumGroup(artist: "A", base: "One", variants: ["One"])
        g.base = "Two – Live"
        #expect(g.groupingKey == "two - live")
    }
}

@Suite struct AlbumGroupingKeyFoldTests {
    @Test(arguments: [
        ("a\u{2013}b", "a-b"), ("a\u{2014}b", "a-b"), ("a\u{2212}b", "a-b"),
        ("\u{2018}x\u{2019}", "'x'"), ("\u{201C}x\u{201D}", "\"x\""), ("wait\u{2026}", "wait..."),
    ])
    func foldsEachCharacter(input: String, expected: String) {
        #expect(albumGroupingKey(input) == expected)
    }

    @Test func leavesOtherNonASCIIAlone() {
        #expect(albumGroupingKey("Motörhead – Ace Of Spades") == "motörhead - ace of spades")
    }
}

@Suite struct CurrentAlbumIdentityTests {
    private func song(_ file: String, album: String, albumartist: String = "", artist: String = "") -> MPDSong {
        var r: MPDRecord = ["file": file, "album": album]
        if !albumartist.isEmpty { r["albumartist"] = albumartist }
        if !artist.isEmpty { r["artist"] = artist }
        return MPDSong(r)
    }

    /// The precomputed overload is what rows call now; it must agree with the
    /// original, whose tests pin the semantics.
    @Test func precomputedOverloadAgreesWithTheOriginal() {
        let songs = [
            song("W/Q/1.flac", album: "Quadrophenia [Disc 2]", albumartist: "The Who"),
            song("B/1967-1970/1.flac", album: "1967–1970", albumartist: "The Beatles"),
            song("http://radio/stream", album: ""),
            song("VA/Jackie Brown/03.mp3", album: "Jackie Brown", artist: "Bill Withers"),
            song("", album: "Quadrophenia"),
        ]
        let rows: [(artist: String, album: String, comp: String?)] = [
            ("The Who", "Quadrophenia", nil), ("the who ", "Quadrophenia [Disc 1]", nil),
            ("The Beatles", "1967-1970", nil), ("Someone Else", "Quadrophenia", nil),
            ("", "Quadrophenia", nil), ("Various Artists", "Jackie Brown", "VA/Jackie Brown"),
            ("Various Artists", "Jackie Brown", "Other/Jackie Brown"), ("X", "", nil),
        ]
        for s in songs {
            for r in rows {
                let original = isCurrentAlbum(rowArtist: r.artist, rowAlbum: r.album,
                                              compilationBase: r.comp, current: s)
                let fast = isCurrentAlbum(rowKey: albumGroupingKey(r.album), rowArtist: r.artist,
                                          compilationBase: r.comp, current: CurrentAlbumIdentity(s))
                #expect(original == fast, "\(s.file) vs \(r)")
            }
        }
    }

    @Test func discVariantLightsTheCollapsedRow() {
        let s = song("W/Q/1.flac", album: "Quadrophenia [Disc 2]", albumartist: "The Who")
        #expect(isCurrentAlbum(rowKey: albumGroupingKey("Quadrophenia"), rowArtist: "The Who",
                               compilationBase: nil, current: CurrentAlbumIdentity(s)))
    }
}

@Suite struct NowPlayingInfoThrottleTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func snap(playing: Bool = true, title: String = "Song", art: Bool = false) -> NowPlayingInfoSnapshot {
        NowPlayingInfoSnapshot(title: title, artist: "A", album: "B", duration: 300,
                               playing: playing, paused: !playing, hasArtwork: art)
    }

    @Test func firstTimeAlwaysUpdates() {
        #expect(nowPlayingInfoNeedsUpdate(last: nil, lastElapsed: 0, lastAt: t0,
                                          current: snap(), elapsed: 0, now: t0))
    }

    /// Steady playback: the system extrapolates, so nothing is re-sent.
    @Test func steadyPlaybackIsNotResent() {
        #expect(!nowPlayingInfoNeedsUpdate(last: snap(), lastElapsed: 10, lastAt: t0,
                                           current: snap(), elapsed: 40.3,
                                           now: t0.addingTimeInterval(30)))
    }

    @Test func aSeekIsResent() {
        #expect(nowPlayingInfoNeedsUpdate(last: snap(), lastElapsed: 10, lastAt: t0,
                                          current: snap(), elapsed: 120,
                                          now: t0.addingTimeInterval(30)))
    }

    /// Paused, elapsed must stand still; the clock moving on is not drift.
    @Test func pausedDoesNotExtrapolate() {
        #expect(!nowPlayingInfoNeedsUpdate(last: snap(playing: false), lastElapsed: 10, lastAt: t0,
                                           current: snap(playing: false), elapsed: 10,
                                           now: t0.addingTimeInterval(600)))
    }

    @Test func stateSongOrArtworkChangesAreResent() {
        for changed in [snap(playing: false), snap(title: "Next"), snap(art: true)] {
            #expect(nowPlayingInfoNeedsUpdate(last: snap(), lastElapsed: 10, lastAt: t0,
                                              current: changed, elapsed: 10, now: t0))
        }
    }
}

@Suite struct AudioFormatTests {
    @Test(arguments: [
        ("44100:16:2", "44.1 kHz · 16-bit · stereo"),
        ("48000:24:2", "48 kHz · 24-bit · stereo"),
        ("96000:24:1", "96 kHz · 24-bit · mono"),
        ("48000:f:2", "48 kHz · 32-bit float · stereo"),
        ("192000:32:6", "192 kHz · 32-bit · 6 ch"),
        ("dsd64:2", "DSD64 · stereo"),
    ])
    func formats(raw: String, expected: String) {
        #expect(formatAudioFormat(raw) == expected)
    }

    /// Showing MPD's own text beats guessing.
    @Test(arguments: ["", "weird", "44100:16", "x:16:2"])
    func unknownIsReturnedUnchanged(raw: String) {
        #expect(formatAudioFormat(raw) == raw)
    }
}

@Suite struct GroupingCostTests {
    /// Not a benchmark — a tripwire. Grouping a large library is now done once per
    /// input change, but it should still be cheap enough not to matter even if a
    /// regression put it back in `body`.
    @Test func groupingAThousandAlbumsIsCheap() {
        let pairs = (0..<1000).map { i in
            (artist: "Artist \(i % 150)", album: i % 7 == 0 ? "Album \(i) [Disc \(i % 3 + 1)]" : "Album \(i)")
        }
        let clock = ContinuousClock()
        let took = clock.measure { _ = sortedAlbumGroups(groupAlbumVariants(pairs), by: .artistAsc) }
        #expect(took < .seconds(1), "took \(took)")
    }
}
