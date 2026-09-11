// MissingPlaylistEntryTests.swift
// Stored playlists outlive the files in them. MPD reports a dead entry as a bare
// file line and silently skips it on `load`; both facts were checked against a
// real 417-entry playlist on MPD 0.24.0 with five such entries.
import Testing
import Foundation
@testable import mikMPD

private func missingSong(_ file: String) -> MPDSong { MPDSong(["file": file]) }

private func librarySong(_ file: String) -> MPDSong {
    MPDSong(["file": file, "title": "T", "duration": "215.0",
             "last-modified": "2021-03-04T10:11:12Z"])
}

@Suite struct MissingPlaylistEntryTests {
    /// Exactly what `listplaylistinfo` returns for a file that is gone.
    @Test func aFileLineWithNothingElseIsMissing() {
        #expect(missingSong("Peter Gabriel/Us/04 - Peter Gabriel - Steam.flac").isMissingFromLibrary)
    }

    @Test func aLibrarySongIsNotMissing() {
        #expect(!librarySong("Foreigner - 4 (1981)/02 - Juke Box Hero.flac").isMissingFromLibrary)
    }

    /// Streams and CD tracks are never in the database — not missing, just not files.
    @Test func streamsAndCDTracksAreNeverMissing() {
        #expect(!missingSong("http://radio.example/stream.mp3").isMissingFromLibrary)
        #expect(!missingSong("cdda:///3").isMissingFromLibrary)
    }

    /// Requiring both signals keeps a date that fails to parse from flagging a
    /// song the library does have.
    @Test func anUnparseableDateAloneDoesNotMakeASongMissing() {
        let s = MPDSong(["file": "a/b.flac", "duration": "200", "last-modified": "not a date"])
        #expect(!s.isMissingFromLibrary)
    }
}

@Suite struct PlaylistQueueIndexTests {
    private func playlist(count: Int, missingAt: Set<Int>) -> [MPDSong] {
        (0..<count).map { i in
            var s = missingAt.contains(i) ? missingSong("gone/\(i).flac") : librarySong("ok/\(i).flac")
            s.pos = i
            return s
        }
    }

    @Test func withNothingMissingEveryRowKeepsItsIndex() {
        let songs = playlist(count: 10, missingAt: [])
        for i in 0..<10 { #expect(playlistQueueIndex(forPlaylistIndex: i, in: songs) == i) }
    }

    /// `load` drops the missing entry, so everything after it moves up a place.
    @Test func rowsAfterAMissingFileMoveUp() {
        let songs = playlist(count: 10, missingAt: [2])
        #expect(playlistQueueIndex(forPlaylistIndex: 1, in: songs) == 1)
        #expect(playlistQueueIndex(forPlaylistIndex: 3, in: songs) == 2)
        #expect(playlistQueueIndex(forPlaylistIndex: 9, in: songs) == 8)
    }

    @Test func aMissingRowHasNoQueuePosition() {
        let songs = playlist(count: 10, missingAt: [2])
        #expect(playlistQueueIndex(forPlaylistIndex: 2, in: songs) == nil)
    }

    @Test func outOfRangeIsNil() {
        let songs = playlist(count: 3, missingAt: [])
        #expect(playlistQueueIndex(forPlaylistIndex: -1, in: songs) == nil)
        #expect(playlistQueueIndex(forPlaylistIndex: 3, in: songs) == nil)
    }

    /// The real playlist that exposed this: 417 entries, dead files at these
    /// positions, loading as 412. Row 300 used to play queue position 300 —
    /// five songs too far.
    @Test func theRealPlaylistMapsLikeMPDLoadsIt() {
        let dead: Set<Int> = [2, 104, 258, 261, 294]
        let songs = playlist(count: 417, missingAt: dead)
        #expect(songs.filter { !$0.isMissingFromLibrary }.count == 412)
        #expect(playlistQueueIndex(forPlaylistIndex: 1, in: songs) == 1)
        #expect(playlistQueueIndex(forPlaylistIndex: 3, in: songs) == 2)
        #expect(playlistQueueIndex(forPlaylistIndex: 294, in: songs) == nil)
        #expect(playlistQueueIndex(forPlaylistIndex: 300, in: songs) == 295)
        #expect(playlistQueueIndex(forPlaylistIndex: 416, in: songs) == 411)
    }
}
