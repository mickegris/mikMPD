import Foundation
import Network
import Testing
@testable import mikMPD

// MARK: - MPDSong

@Suite struct MPDSongTests {
    @Test func initFromFullRecord() {
        let record: MPDRecord = [
            "file": "Music/Artist/Album/01 Song.flac",
            "title": "Test Song",
            "artist": "Test Artist",
            "album": "Test Album",
            "track": "3/12",
            "duration": "245.5",
            "pos": "7",
            "id": "42"
        ]
        let song = MPDSong(record)
        #expect(song.file == "Music/Artist/Album/01 Song.flac")
        #expect(song.title == "Test Song")
        #expect(song.artist == "Test Artist")
        #expect(song.album == "Test Album")
        #expect(song.track == "3/12")
        #expect(song.duration == 245.5)
        #expect(song.pos == 7)
        #expect(song.songID == "42")
    }

    @Test func initFromEmptyRecord() {
        let song = MPDSong([:])
        #expect(song.file.isEmpty)
        #expect(song.title.isEmpty)
        #expect(song.duration == 0)
        #expect(song.pos == 0)
        #expect(song.songID.isEmpty)
    }

    @Test func idUsesSongIDWhenPresent() {
        var song = MPDSong()
        song.songID = "99"
        song.pos = 5
        song.file = "test.flac"
        #expect(song.id == "99")
    }

    @Test func idFallsBackToPosAndFile() {
        var song = MPDSong()
        song.pos = 5
        song.file = "test.flac"
        #expect(song.id == "5:test.flac")
    }

    @Test func displayTitleUsesTitle() {
        var song = MPDSong()
        song.title = "My Song"
        song.file = "path/to/file.flac"
        #expect(song.displayTitle == "My Song")
    }

    @Test func displayTitleFallsBackToFilename() {
        var song = MPDSong()
        song.file = "Music/Artist/Album/01 Song.flac"
        #expect(song.displayTitle == "01 Song.flac")
    }

    @Test func trackNumberParsesSimple() {
        var song = MPDSong()
        song.track = "7"
        #expect(song.trackNumber == 7)
    }

    @Test func trackNumberParsesSlashFormat() {
        var song = MPDSong()
        song.track = "3/12"
        #expect(song.trackNumber == 3)
    }

    @Test func trackNumberReturnsZeroForEmpty() {
        #expect(MPDSong().trackNumber == 0)
    }

    @Test func artKeyIsLowercased() {
        var song = MPDSong()
        song.artist = "The Beatles"
        song.album = "Abbey Road"
        #expect(song.artKey == "the beatles|abbey road")
    }

    @Test @MainActor func equatable() {
        let r: MPDRecord = ["file": "a.flac", "id": "1"]
        #expect(MPDSong(r) == MPDSong(r))
    }
}

// MARK: - artCacheKey

@Suite struct ArtCacheKeyTests {
    @Test func trimsWhitespace() {
        #expect(artCacheKey(artist: " The Beatles ", album: "\tAbbey Road\n") == "the beatles|abbey road")
    }

    @Test func bothEmptyReturnsEmptyKey() {
        #expect(artCacheKey(artist: "", album: "") == "")
        #expect(artCacheKey(artist: "  ", album: "\n") == "")
    }

    @Test func oneEmptyKeepsSeparator() {
        #expect(artCacheKey(artist: "Artist", album: "") == "artist|")
        #expect(artCacheKey(artist: "", album: "Album") == "|album")
    }

    @Test func matchesSongArtKey() {
        var song = MPDSong()
        song.artist = " Some Artist "
        song.album = "Some Album"
        #expect(song.artKey == artCacheKey(artist: " Some Artist ", album: "Some Album"))
    }
}

// MARK: - mpdMoveTarget

@Suite struct MoveTargetTests {
    // SwiftUI onMove reports the destination as an index into the array
    // before the moved row is removed; MPD wants the index after removal.
    @Test func movingDownSubtractsOne() {
        #expect(mpdMoveTarget(from: 1, to: 4) == 3)
        #expect(mpdMoveTarget(from: 0, to: 5) == 4)
    }

    @Test func movingUpIsUnchanged() {
        #expect(mpdMoveTarget(from: 3, to: 1) == 1)
        #expect(mpdMoveTarget(from: 5, to: 0) == 0)
    }

    @Test func droppingInPlaceYieldsSameIndex() {
        #expect(mpdMoveTarget(from: 2, to: 2) == 2)
        // Dropping directly below itself is also a no-op after adjustment
        #expect(mpdMoveTarget(from: 2, to: 3) == 2)
    }
}

// MARK: - PlaybackSourceKind

@Suite struct SourceKindTests {
    private func song(file: String) -> MPDSong {
        var s = MPDSong()
        s.file = file
        return s
    }

    @Test func cdTrack() {
        #expect(song(file: "cdda://1").sourceKind == .cd)
        #expect(song(file: "CDDA://2").sourceKind == .cd)
    }

    @Test func radioStreams() {
        #expect(song(file: "http://stream.example.com:8080/radio").sourceKind == .radio)
        #expect(song(file: "https://live1.sr.se/p2-flac").sourceKind == .radio)
    }

    @Test func libraryPaths() {
        #expect(song(file: "Music/Artist/Album/01 Song.flac").sourceKind == .library)
        #expect(song(file: "").sourceKind == .library)
        // A colon in a path component must not be mistaken for a URL scheme
        #expect(song(file: "Genesis: Live/track.flac").sourceKind == .library)
    }

    @Test func fallbackAssetPerKind() {
        #expect(song(file: "Music/a.flac").fallbackArtAssetName == "MikMPDLogo")
        #expect(song(file: "http://x/r").fallbackArtAssetName == "RadioFallbackArt")
        #expect(song(file: "cdda://1").fallbackArtAssetName == "CDFallbackArt")
    }
}

// MARK: - MPDOutput

@Suite struct MPDOutputTests {
    @Test func initFromRecord() {
        let record: MPDRecord = [
            "outputid": "0",
            "outputname": "My Speaker",
            "outputenabled": "1",
            "plugin": "alsa"
        ]
        let output = MPDOutput(record)
        #expect(output.outputID == "0")
        #expect(output.name == "My Speaker")
        #expect(output.enabled == true)
        #expect(output.plugin == "alsa")
    }

    @Test func disabledOutput() {
        let output = MPDOutput(["outputid": "1", "outputname": "HP", "outputenabled": "0", "plugin": "pulse"])
        #expect(output.enabled == false)
    }

    @Test func missingFieldsUseDefaults() {
        let output = MPDOutput([:])
        #expect(output.name == "Output")
        #expect(output.enabled == false)
        #expect(output.plugin.isEmpty)
        #expect(!output.outputID.isEmpty)
    }
}

// MARK: - MPDBrowseItem

@Suite struct MPDBrowseItemTests {
    @Test func directoryProperties() {
        let item = MPDBrowseItem(kind: .directory, path: "Music/Rock")
        #expect(item.id == "d:Music/Rock")
        #expect(item.displayName == "Rock")
        #expect(item.sfSymbol == "folder.fill")
    }

    @Test func fileProperties() {
        let item = MPDBrowseItem(kind: .file, path: "Music/Rock/song.flac")
        #expect(item.id == "f:Music/Rock/song.flac")
        #expect(item.displayName == "song.flac")
        #expect(item.sfSymbol == "music.note")
    }

    @Test func playlistProperties() {
        let item = MPDBrowseItem(kind: .playlist, path: "favorites.m3u")
        #expect(item.id == "p:favorites.m3u")
        #expect(item.displayName == "favorites.m3u")
        #expect(item.sfSymbol == "list.bullet.rectangle")
    }
}

// MARK: - formatTime

@Suite struct FormatTimeTests {
    @Test func zero() {
        #expect(formatTime(0) == "0:00")
    }

    @Test func negative() {
        #expect(formatTime(-5) == "0:00")
    }

    @Test func normalValue() {
        #expect(formatTime(65) == "1:05")
    }

    @Test func exactMinute() {
        #expect(formatTime(120) == "2:00")
    }

    @Test func largeValue() {
        #expect(formatTime(3661) == "61:01")
    }

    @Test func fractionalSecondsRoundDown() {
        #expect(formatTime(90.7) == "1:30")
    }

    @Test func nan() {
        #expect(formatTime(Double.nan) == "0:00")
    }

    @Test func infinity() {
        #expect(formatTime(Double.infinity) == "0:00")
    }
}

// MARK: - String.esc

@Suite struct StringEscTests {
    @Test func plainString() {
        #expect("hello".esc == "hello")
    }

    @Test func emptyString() {
        #expect("".esc == "")
    }

    @Test func escapesQuotes() {
        #expect("say \"hi\"".esc == "say \\\"hi\\\"")
    }

    @Test func escapesBackslashes() {
        #expect("path\\to".esc == "path\\\\to")
    }

    @Test func escapesBothInOrder() {
        #expect("a\\\"b".esc == "a\\\\\\\"b")
    }
}

// MARK: - Double.clamped

@Suite struct ClampedTests {
    @Test func belowRange() {
        #expect((-5.0).clamped(to: 0...1) == 0)
    }

    @Test func aboveRange() {
        #expect(5.0.clamped(to: 0...1) == 1)
    }

    @Test func withinRange() {
        #expect(0.5.clamped(to: 0...1) == 0.5)
    }

    @Test func atBounds() {
        #expect(0.0.clamped(to: 0...1) == 0)
        #expect(1.0.clamped(to: 0...1) == 1)
    }
}

// MARK: - parseMPDRecords

@Suite struct ParseRecordsTests {
    @Test func singleRecord() {
        let lines = [
            "file: Music/song.flac",
            "Title: Test Song",
            "Artist: Test Artist",
        ]
        let records = parseMPDRecords(lines)
        #expect(records.count == 1)
        #expect(records[0]["file"] == "Music/song.flac")
        #expect(records[0]["title"] == "Test Song")
        #expect(records[0]["artist"] == "Test Artist")
    }

    @Test func multipleRecordsSplitOnFile() {
        let lines = [
            "file: song1.flac",
            "title: First",
            "file: song2.flac",
            "title: Second",
        ]
        let records = parseMPDRecords(lines)
        #expect(records.count == 2)
        #expect(records[0]["title"] == "First")
        #expect(records[1]["title"] == "Second")
    }

    @Test func emptyInput() {
        #expect(parseMPDRecords([]).isEmpty)
    }

    @Test func malformedLinesSkipped() {
        let lines = [
            "file: test.flac",
            "no colon here",
            "title: Works",
        ]
        let records = parseMPDRecords(lines)
        #expect(records.count == 1)
        #expect(records[0]["title"] == "Works")
    }

    @Test func directoryStarterKey() {
        let records = parseMPDRecords([
            "directory: Music",
            "directory: Videos",
        ])
        #expect(records.count == 2)
        #expect(records[0]["directory"] == "Music")
        #expect(records[1]["directory"] == "Videos")
    }

    @Test func outputRecords() {
        let records = parseMPDRecords([
            "outputid: 0",
            "outputname: Speaker",
            "outputenabled: 1",
            "outputid: 1",
            "outputname: Headphones",
            "outputenabled: 0",
        ])
        #expect(records.count == 2)
        #expect(records[0]["outputname"] == "Speaker")
        #expect(records[1]["outputname"] == "Headphones")
    }

    @Test func partitionRecords() {
        let records = parseMPDRecords([
            "partition: default",
            "partition: zone2",
        ])
        #expect(records.count == 2)
        #expect(records[0]["partition"] == "default")
        #expect(records[1]["partition"] == "zone2")
    }

    @Test func keysAreLowercased() {
        let records = parseMPDRecords([
            "file: test.flac",
            "Title: My Song",
            "ARTIST: Someone",
        ])
        #expect(records[0]["title"] == "My Song")
        #expect(records[0]["artist"] == "Someone")
    }

    @Test func valuesWithColonsPreserved() {
        let records = parseMPDRecords([
            "file: http://stream.example.com:8080/radio",
        ])
        #expect(records[0]["file"] == "http://stream.example.com:8080/radio")
    }

    @Test func mixedRecordTypes() {
        let records = parseMPDRecords([
            "directory: Music",
            "file: readme.txt",
            "playlist: favorites.m3u",
        ])
        #expect(records.count == 3)
    }

    @Test func nonStarterKeyDoesNotFlush() {
        let records = parseMPDRecords([
            "file: song.flac",
            "title: Song",
            "artist: Artist",
            "album: Album",
        ])
        #expect(records.count == 1)
        #expect(records[0].count == 4)
    }

    @Test func playlistStarterKey() {
        let records = parseMPDRecords([
            "playlist: list1.m3u",
            "last-modified: 2024-01-01",
            "playlist: list2.m3u",
        ])
        #expect(records.count == 2)
        #expect(records[0]["last-modified"] == "2024-01-01")
    }
}

// MARK: - parseStreamURL

@Suite struct ParseStreamURLTests {
    @Test func validHTTPURL() {
        let url = MPDStore.parseStreamURL("http://klova.frillesas.se:55441/")
        #expect(url?.absoluteString == "http://klova.frillesas.se:55441/")
    }

    @Test func validHTTPSURL() {
        let url = MPDStore.parseStreamURL("https://example.com/stream")
        #expect(url?.absoluteString == "https://example.com/stream")
    }

    @Test func emptyString() {
        #expect(MPDStore.parseStreamURL("") == nil)
    }

    @Test func whitespaceOnly() {
        #expect(MPDStore.parseStreamURL("   ") == nil)
    }

    @Test func leadingTrailingWhitespace() {
        let url = MPDStore.parseStreamURL("  http://example.com/  ")
        #expect(url?.absoluteString == "http://example.com/")
    }

    @Test func noScheme() {
        #expect(MPDStore.parseStreamURL("example.com:8080/stream") == nil)
    }

    @Test func schemeOnlyNoHost() {
        #expect(MPDStore.parseStreamURL("http://") == nil)
    }

    @Test func noHostWithPath() {
        #expect(MPDStore.parseStreamURL("http:///path") == nil)
    }

    @Test func ftpSchemeRejected() {
        #expect(MPDStore.parseStreamURL("ftp://example.com/stream") == nil)
    }

    @Test func uppercaseScheme() {
        let url = MPDStore.parseStreamURL("HTTP://example.com/stream")
        #expect(url?.absoluteString == "HTTP://example.com/stream")
    }
}

// MARK: - Phone streaming (regression: isolation trap on bg poll timer)

@Suite struct PhoneStreamTests {
    @Test @MainActor func startingStreamDoesNotTrapIsolationChecks() async throws {
        let store = MPDStore()
        store.httpStreamURL = "http://127.0.0.1:9/stream"
        store.startPhoneStream()
        // The background poll timer fires on Q after 2s; give it time to
        // trip dispatch_assert_queue if any handler is MainActor-inferred.
        try await Task.sleep(for: .seconds(5))
        store.stopPhoneStream()
        #expect(!store.isPhoneStreaming)
    }
}

// MARK: - Server discovery

@Suite struct DiscoveryHostTests {
    @Test func hostnamePassesThrough() {
        #expect(MPDDiscoveryService.displayHost(.name("klova.local", nil)) == "klova.local")
    }

    @Test func ipv4Renders() {
        #expect(MPDDiscoveryService.displayHost(.ipv4(IPv4Address("192.168.1.5")!)) == "192.168.1.5")
    }

    @Test func ipv6ScopeSuffixStripped() {
        let host = MPDDiscoveryService.displayHost(.ipv6(IPv6Address("fe80::1%en0")!))
        #expect(!host.contains("%"))
        #expect(host.hasPrefix("fe80::1"))
    }
}

// MARK: - MPDServerProfile

@Suite struct ServerProfileTests {
    @Test @MainActor func codableRoundtrip() throws {
        let servers = [
            MPDServerProfile(name: "Living room", host: "10.0.0.5", port: 6601,
                             streamURL: "http://10.0.0.5:8000/", lastPartition: "zone2"),
            MPDServerProfile(name: "Office", host: "office.local"),
        ]
        let data = try JSONEncoder().encode(servers)
        let decoded = try JSONDecoder().decode([MPDServerProfile].self, from: data)
        #expect(decoded == servers)
    }

    @Test func migrationUsesHostAsName() {
        let profile = migratedLegacyProfile(host: "mpd.local", portStr: "6600",
                                            streamURL: "http://mpd.local:8000/", lastPartition: nil)
        #expect(profile.name == "mpd.local")
        #expect(profile.host == "mpd.local")
        #expect(profile.port == 6600)
        #expect(profile.streamURL == "http://mpd.local:8000/")
        #expect(profile.lastPartition == "")
    }

    @Test func migrationFallsBackOnBadPort() {
        #expect(migratedLegacyProfile(host: "h", portStr: "abc", streamURL: "", lastPartition: "p").port == 6600)
        #expect(migratedLegacyProfile(host: "h", portStr: "6601", streamURL: "", lastPartition: "p").lastPartition == "p")
    }

    @Test func passwordKeyFallsBackToLegacy() {
        #expect(MPDStore.passwordKey(forServerID: "") == "mpd_password")
        #expect(MPDStore.passwordKey(forServerID: "ABC") == "mpd_password_ABC")
    }
}

// MARK: - Wikipedia album matching

@Suite struct WikipediaAlbumMatchTests {
    @Test func enDashTitleMatchesHyphenTag() {
        // Wikipedia titles ranges with en dashes; tags usually carry hyphens
        #expect(WikipediaService.albumResultMatches(
            title: "1967\u{2013}1970",
            extract: "1967\u{2013}1970 is a compilation album of songs by the English rock band the Beatles.",
            album: "1967-1970",
            artist: "The Beatles"))
    }

    @Test func plainTitleStillMatches() {
        #expect(WikipediaService.albumResultMatches(
            title: "Abbey Road",
            extract: "Abbey Road is the eleventh studio album by the English rock band the Beatles.",
            album: "Abbey Road",
            artist: "The Beatles"))
    }

    @Test func unrelatedAlbumRejected() {
        #expect(!WikipediaService.albumResultMatches(
            title: "The Beatles discography",
            extract: "The English rock band the Beatles have released 12 studio albums.",
            album: "1967-1970",
            artist: "The Beatles"))
    }

    @Test func wrongArtistRejected() {
        #expect(!WikipediaService.albumResultMatches(
            title: "Greatest Hits",
            extract: "Greatest Hits is a compilation album by the American rock band Journey.",
            album: "Greatest Hits",
            artist: "Queen"))
    }
}

// MARK: - Stored playlists

@Suite struct PlaylistNameTests {
    @Test func trimsValidName() {
        #expect(validatePlaylistName("  My List ") == "My List")
        #expect(validatePlaylistName("Favorites") == "Favorites")
    }

    @Test func rejectsEmpty() {
        #expect(validatePlaylistName("") == nil)
        #expect(validatePlaylistName("   ") == nil)
    }

    @Test func rejectsPathSeparatorsAndNewlines() {
        #expect(validatePlaylistName("a/b") == nil)
        #expect(validatePlaylistName("a\\b") == nil)
        #expect(validatePlaylistName("a\nb") == nil)
    }
}

@Suite struct PlaylistSongsTests {
    @Test func assignsPositionsFromIndex() {
        let records: [MPDRecord] = [
            ["file": "a.flac", "title": "One"],
            ["file": "b.flac", "title": "Two"],
        ]
        let songs = songsAssigningPositions(records)
        #expect(songs.count == 2)
        #expect(songs[0].pos == 0)
        #expect(songs[1].pos == 1)
    }

    @Test func duplicateFilesGetDistinctIds() {
        // listplaylistinfo returns no pos/id; without index assignment two
        // copies of the same file would collide on MPDSong.id
        let records: [MPDRecord] = [
            ["file": "same.flac"],
            ["file": "same.flac"],
        ]
        let songs = songsAssigningPositions(records)
        #expect(songs[0].id != songs[1].id)
    }
}

@Suite struct MPDPlaylistTests {
    @Test func idIsName() {
        #expect(MPDPlaylist(name: "Road Trip").id == "Road Trip")
    }
}

// MARK: - ackMessage

@Suite struct AckMessageTests {
    @Test func stripsAckPrefix() {
        #expect(MPDStore.ackMessage("ACK [50@0] {delpartition} it's not empty") == "it's not empty")
        #expect(MPDStore.ackMessage("ACK [56@0] {newpartition} name already exists") == "name already exists")
    }

    @Test func nonAckPassesThrough() {
        #expect(MPDStore.ackMessage("Not connected") == "Not connected")
        #expect(MPDStore.ackMessage("") == "")
    }

    @Test func malformedAckPassesThrough() {
        #expect(MPDStore.ackMessage("ACK weird format") == "ACK weird format")
    }

    @Test func messageMayContainBraces() {
        #expect(MPDStore.ackMessage("ACK [5@0] {load} No such playlist: {x}") == "No such playlist: {x}")
    }
}

// MARK: - SavedStation

@Suite struct SavedStationTests {
    @Test func idIsURL() {
        let station = SavedStation(name: "Test", url: "http://example.com/stream")
        #expect(station.id == "http://example.com/stream")
    }

    @Test @MainActor func codableRoundtrip() throws {
        let stations = [
            SavedStation(name: "Station 1", url: "http://a.com"),
            SavedStation(name: "Station 2", url: "http://b.com"),
        ]
        let data = try JSONEncoder().encode(stations)
        let decoded = try JSONDecoder().decode([SavedStation].self, from: data)
        #expect(decoded == stations)
    }
}

// MARK: - Lyrics (LRC parsing)

@Suite struct LyricsParseTests {
    @Test func basicTimestamps() {
        let lrc = "[00:12.34] First line\n[00:15.00] Second line\n"
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines?.count == 2)
        #expect(abs((lines?[0].secs ?? 0) - 12.34) < 0.01)
        #expect(lines?[0].text == "First line")
        #expect(abs((lines?[1].secs ?? 0) - 15.0) < 0.01)
        #expect(lines?[1].text == "Second line")
    }

    @Test func sortsByTime() {
        let lrc = "[00:20.00] Late line\n[00:05.00] Early line\n"
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines?.count == 2)
        #expect(abs((lines?[0].secs ?? 0) - 5.0) < 0.01)
        #expect(lines?[0].text == "Early line")
    }

    @Test func skipsMalformedTimestamps() {
        let lrc = "[bad] garbage line\n[00:10.00] Good line\n"
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines?.count == 1)
        #expect(lines?[0].text == "Good line")
    }

    @Test func integerSecondsWithoutFraction() {
        let lines = LyricsService.parseLRC("[01:30] Whole seconds only\n")
        #expect(abs((lines?[0].secs ?? 0) - 90.0) < 0.01)
    }

    @Test func emptyInputReturnsNil() {
        #expect(LyricsService.parseLRC("") == nil)
        #expect(LyricsService.parseLRC("   \n  ") == nil)
    }

    @Test func preservesBlankLyricLinesAsSpacers() {
        let lrc = "[00:01.00] Verse\n[00:02.00]\n[00:03.00] Chorus\n"
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines?.count == 3)
        #expect(lines?[1].text == "")
    }
}

// MARK: - Recently played recorder

@Suite struct RecentlyPlayedRecorderTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func song(file: String = "a.mp3", duration: Double = 300) -> MPDSong {
        var s = MPDSong()
        s.file = file; s.title = "Title"; s.artist = "Artist"; s.album = "Album"
        s.duration = duration
        return s
    }

    /// Ticks every second for `seconds`, returning the first committed entry.
    private func play(_ r: inout RecentlyPlayedRecorder, _ s: MPDSong,
                      from: TimeInterval, seconds: Int, playing: Bool = true) -> RecentlyPlayedEntry? {
        var entry: RecentlyPlayedEntry? = nil
        for i in 0...seconds {
            let e = r.tick(song: s, isPlaying: playing, now: t0.addingTimeInterval(from + Double(i)))
            if entry == nil { entry = e }
        }
        return entry
    }

    @Test func commitsAfterThirtySeconds() {
        var r = RecentlyPlayedRecorder()
        let entry = play(&r, song(), from: 0, seconds: 30)
        #expect(entry != nil)
        #expect(entry?.file == "a.mp3")
        #expect(entry?.title == "Title")
    }

    @Test func doesNotCommitBeforeThreshold() {
        var r = RecentlyPlayedRecorder()
        #expect(play(&r, song(), from: 0, seconds: 20) == nil)
    }

    @Test func noSecondCommitWhileSameFileKeepsPlaying() {
        var r = RecentlyPlayedRecorder()
        #expect(play(&r, song(), from: 0, seconds: 30) != nil)
        #expect(play(&r, song(), from: 31, seconds: 120) == nil)
    }

    @Test func skippedSongNeverCommits() {
        var r = RecentlyPlayedRecorder()
        #expect(play(&r, song(file: "skipped.mp3"), from: 0, seconds: 10) == nil)
        // Switching files resets — the new song commits, the skipped one is gone
        let entry = play(&r, song(file: "next.mp3"), from: 11, seconds: 31)
        #expect(entry?.file == "next.mp3")
    }

    @Test func pauseFreezesAccumulationButKeepsProgress() {
        var r = RecentlyPlayedRecorder()
        #expect(play(&r, song(), from: 0, seconds: 20) == nil)
        // Paused for a long stretch: no progress
        #expect(play(&r, song(), from: 100, seconds: 200, playing: false) == nil)
        // Resume: only ~10 more seconds needed
        #expect(play(&r, song(), from: 400, seconds: 12) != nil)
    }

    @Test func largeTickGapIsCapped() {
        var r = RecentlyPlayedRecorder()
        _ = r.tick(song: song(), isPlaying: true, now: t0)
        // One minute between ticks (app suspended) counts as at most 5 s
        #expect(r.tick(song: song(), isPlaying: true, now: t0.addingTimeInterval(60)) == nil)
        #expect(r.tick(song: song(), isPlaying: true, now: t0.addingTimeInterval(120)) == nil)
    }

    @Test func shortTrackCommitsAtHalfDuration() {
        var r = RecentlyPlayedRecorder()
        #expect(play(&r, song(duration: 20), from: 0, seconds: 10) != nil)
    }

    @Test func unknownDurationUsesThirtySeconds() {
        var r = RecentlyPlayedRecorder()
        #expect(play(&r, song(file: "http://radio/stream", duration: 0), from: 0, seconds: 20) == nil)
        #expect(play(&r, song(file: "http://radio/stream", duration: 0), from: 21, seconds: 10) != nil)
    }

    @Test func stopThenReplayCommitsAgain() {
        var r = RecentlyPlayedRecorder()
        #expect(play(&r, song(), from: 0, seconds: 30) != nil)
        _ = r.tick(song: MPDSong(), isPlaying: false, now: t0.addingTimeInterval(40))  // stopped
        #expect(play(&r, song(), from: 50, seconds: 30) != nil)
    }
}

// MARK: - Recently played retention

@Suite struct RecentHistoryPruneTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func entry(ageSeconds: TimeInterval) -> RecentlyPlayedEntry {
        RecentlyPlayedEntry(file: "f\(ageSeconds)", title: "t", artist: "a", album: "l",
                            playedAt: now.addingTimeInterval(-ageSeconds))
    }

    @Test func dropsOldEntries() {
        let entries = [entry(ageSeconds: 10), entry(ageSeconds: 100)]
        let pruned = prunedRecentHistory(entries, now: now, maxAge: 50, cap: 100)
        #expect(pruned.count == 1)
        #expect(pruned[0].playedAt == now.addingTimeInterval(-10))
    }

    @Test func capsToNewest() {
        let entries = (0..<10).map { entry(ageSeconds: Double($0)) }
        let pruned = prunedRecentHistory(entries, now: now, maxAge: 1000, cap: 3)
        #expect(pruned.count == 3)
        #expect(pruned[0].playedAt == now)
    }

    @Test func bothLimitsTogether() {
        let entries = [entry(ageSeconds: 1), entry(ageSeconds: 2), entry(ageSeconds: 999)]
        let pruned = prunedRecentHistory(entries, now: now, maxAge: 100, cap: 1)
        #expect(pruned.count == 1)
    }

    @Test func emptyInput() {
        #expect(prunedRecentHistory([], now: now).isEmpty)
    }

    @Test func codableRoundtrip() throws {
        let e = entry(ageSeconds: 5)
        let decoded = try JSONDecoder().decode(RecentlyPlayedEntry.self,
                                               from: JSONEncoder().encode(e))
        #expect(decoded == e)
        #expect(decoded.id == e.id)
    }
}

// MARK: - Legacy server migration gate

@Suite struct LegacyMigrationTests {
    @Test func freshInstallDoesNotMigrate() {
        // No persisted legacy host: the old @AppStorage default was never
        // written to UserDefaults, so nothing should be invented.
        #expect(!shouldMigrateLegacyServer(persistedHost: nil, hasServers: false))
    }

    @Test func persistedLegacyHostMigrates() {
        #expect(shouldMigrateLegacyServer(persistedHost: "192.168.1.1", hasServers: false))
        #expect(shouldMigrateLegacyServer(persistedHost: "myhost.local", hasServers: false))
    }

    @Test func emptyOrBlankHostDoesNotMigrate() {
        #expect(!shouldMigrateLegacyServer(persistedHost: "", hasServers: false))
        #expect(!shouldMigrateLegacyServer(persistedHost: "   ", hasServers: false))
    }

    @Test func existingServersNeverMigrate() {
        #expect(!shouldMigrateLegacyServer(persistedHost: "myhost", hasServers: true))
        #expect(!shouldMigrateLegacyServer(persistedHost: nil, hasServers: true))
    }
}

// MARK: - Multi-disc album markers

@Suite struct AlbumDiscTests {
    @Test func bracketDisc() {
        let r = albumBaseAndDisc("Blast from the Past [Disc 1]")
        #expect(r.base == "Blast from the Past")
        #expect(r.disc == 1)
    }

    @Test func parenDisc() {
        let r = albumBaseAndDisc("Album (Disc 2)")
        #expect(r.base == "Album")
        #expect(r.disc == 2)
    }

    @Test func diskSpelling() {
        let r = albumBaseAndDisc("Album [Disk 3]")
        #expect(r.base == "Album")
        #expect(r.disc == 3)
    }

    @Test func cdInParens() {
        let r = albumBaseAndDisc("Album (CD 1)")
        #expect(r.base == "Album")
        #expect(r.disc == 1)
    }

    @Test func bareCDWithoutSpace() {
        let r = albumBaseAndDisc("Album CD2")
        #expect(r.base == "Album")
        #expect(r.disc == 2)
    }

    @Test func dashSeparator() {
        let r = albumBaseAndDisc("Album - Disc 1")
        #expect(r.base == "Album")
        #expect(r.disc == 1)
    }

    @Test func colonSeparatorAndTwoDigits() {
        let r = albumBaseAndDisc("Album: disc 12")
        #expect(r.base == "Album")
        #expect(r.disc == 12)
    }

    @Test func commaSeparator() {
        let r = albumBaseAndDisc("Album, Disc 2")
        #expect(r.base == "Album")
        #expect(r.disc == 2)
    }

    @Test func caseInsensitive() {
        let r = albumBaseAndDisc("ALBUM [DISC 2]")
        #expect(r.base == "ALBUM")
        #expect(r.disc == 2)
    }

    @Test func noMarkerPassesThrough() {
        let r = albumBaseAndDisc("Powerslave")
        #expect(r.base == "Powerslave")
        #expect(r.disc == nil)
    }

    @Test func markerOnlyPassesThrough() {
        let r = albumBaseAndDisc("Disc 1")
        #expect(r.base == "Disc 1")
        #expect(r.disc == nil)
    }

    @Test func leadingSpaceMarkerOnlyPassesThrough() {
        let r = albumBaseAndDisc(" [Disc 1]")
        #expect(r.base == " [Disc 1]")
        #expect(r.disc == nil)
    }

    @Test func noDigitsPassesThrough() {
        let r = albumBaseAndDisc("Live CD")
        #expect(r.base == "Live CD")
        #expect(r.disc == nil)
    }

    @Test func embeddedLettersAreNotAMarker() {
        let r = albumBaseAndDisc("ABCD2")
        #expect(r.base == "ABCD2")
        #expect(r.disc == nil)
    }

    @Test func subtitleAfterMarkerLeftAlone() {
        let r = albumBaseAndDisc("Album [Disc 1] (Bonus)")
        #expect(r.base == "Album [Disc 1] (Bonus)")
        #expect(r.disc == nil)
    }

    @Test func bracketedDiscLetters() {
        let a = albumBaseAndDisc("101 [Disc A]")
        #expect(a.base == "101")
        #expect(a.disc == 1)
        let b = albumBaseAndDisc("101 [Disc B]")
        #expect(b.base == "101")
        #expect(b.disc == 2)
    }

    @Test func bareDiscLetterNotMatched() {
        let r = albumBaseAndDisc("Album CD A")
        #expect(r.base == "Album CD A")
        #expect(r.disc == nil)
    }

    @Test func discLetterVariantsGroup() {
        let g = groupAlbumVariants(["101 [Disc A]", "101 [Disc B]"])
        #expect(g.count == 1)
        #expect(g[0].base == "101")
        #expect(g[0].variants.count == 2)
    }

    @Test func discVariantsShareArtCacheKey() {
        let a = artCacheKey(artist: "Gamma Ray", album: "Blast from the Past [Disc 1]")
        let b = artCacheKey(artist: "Gamma Ray", album: "Blast from the Past (Disc 2)")
        #expect(a == b)
        #expect(a == "gamma ray|blast from the past")
    }

    @Test func strippedAlbumMatchesWikipediaTitle() {
        let base = albumBaseAndDisc("Blast from the Past [Disc 1]").base
        let ok = WikipediaService.albumResultMatches(
            title: "Blast from the Past (Gamma Ray album)",
            extract: "Blast from the Past is a compilation album by Gamma Ray.",
            album: base, artist: "Gamma Ray")
        #expect(ok)
    }
}

// MARK: - Edition qualifiers (external lookups only)

@Suite struct AlbumLookupTitleTests {
    @Test func bitRemaster() {
        #expect(albumLookupTitle("Clutching at Straws [24-bit remaster]") == "Clutching at Straws")
    }

    @Test func yearRemaster() {
        #expect(albumLookupTitle("Crest of a Knave [2005 Remaster]") == "Crest of a Knave")
    }

    @Test func deluxeEditionParens() {
        #expect(albumLookupTitle("The Wall (Deluxe Edition)") == "The Wall")
    }

    @Test func liveQualifier() {
        #expect(albumLookupTitle("Made in Japan (Live)") == "Made in Japan")
    }

    @Test func discMarkerPlusQualifier() {
        #expect(albumLookupTitle("X [Deluxe Edition] [Disc 1]") == "X")
        #expect(albumLookupTitle("X [Disc 1]") == "X")
    }

    @Test func discLetterStripped() {
        #expect(albumLookupTitle("101 [Disc A]") == "101")
    }

    @Test func nonQualifierBracketsKept() {
        #expect(albumLookupTitle("S&M (Symphony & Metallica)") == "S&M (Symphony & Metallica)")
    }

    @Test func leadingBracketUntouched() {
        #expect(albumLookupTitle("(What's the Story) Morning Glory?") == "(What's the Story) Morning Glory?")
    }

    @Test func remixesNotStripped() {
        #expect(albumLookupTitle("Reload [Remixes]") == "Reload [Remixes]")
    }

    @Test func plainTitleUntouched() {
        #expect(albumLookupTitle("Powerslave") == "Powerslave")
    }

    @Test func qualifierOnlyTitleKept() {
        #expect(albumLookupTitle("(Live)") == "(Live)")
    }

    @Test func catalogNumberQualifiers() {
        #expect(albumLookupTitle("Black Rain (Original 88697…)") == "Black Rain")
        #expect(albumLookupTitle("Helldorado {Japan, VICP-60852}") == "Helldorado")
        #expect(albumLookupTitle("Helldorado {Japan, VICP...}") == "Helldorado")
    }

    @Test func curlyBraceDiscMarker() {
        let r = albumBaseAndDisc("X {Disc 1}")
        #expect(r.base == "X")
        #expect(r.disc == 1)
    }

    @Test func partNumberIsNotAQualifier() {
        // "Part 2" (word + space + digit) must survive — it's part of the title
        #expect(albumLookupTitle("Blood of Emeralds - The Very Best of Gary Moore Part 2")
                == "Blood of Emeralds - The Very Best of Gary Moore Part 2")
        #expect(albumLookupTitle("Album (Part 2)") == "Album (Part 2)")
    }
}

// MARK: - Grouped list parsing (list album group albumartist)

@Suite struct GroupedListParseTests {
    @Test func interleavedGroups() {
        let lines = [
            "AlbumArtist: Gamma Ray",
            "Album: Blast from the Past [Disc 1]",
            "Album: Blast from the Past [Disc 2]",
            "AlbumArtist: The Doors",
            "Album: The Best of the Doors",
        ]
        let pairs = parseGroupedValues(lines, groupKey: "albumartist", valueKey: "album")
        #expect(pairs.count == 3)
        #expect(pairs[0].group == "Gamma Ray")
        #expect(pairs[0].value == "Blast from the Past [Disc 1]")
        #expect(pairs[1].group == "Gamma Ray")
        #expect(pairs[2].group == "The Doors")
        #expect(pairs[2].value == "The Best of the Doors")
    }

    @Test func valuesBeforeFirstGroupGetEmptyGroup() {
        let pairs = parseGroupedValues(["Album: Orphan", "AlbumArtist: X", "Album: A"],
                                       groupKey: "albumartist", valueKey: "album")
        #expect(pairs.count == 2)
        #expect(pairs[0].group.isEmpty)
        #expect(pairs[1].group == "X")
    }

    @Test func otherKeysAndMalformedLinesIgnored() {
        let pairs = parseGroupedValues(["Date: 1999", "no colon here", "AlbumArtist: X", "Album: A"],
                                       groupKey: "albumartist", valueKey: "album")
        #expect(pairs.count == 1)
        #expect(pairs[0].group == "X")
    }

    @Test func keysMatchCaseInsensitively() {
        let pairs = parseGroupedValues(["albumartist: X", "ALBUM: A"],
                                       groupKey: "AlbumArtist", valueKey: "Album")
        #expect(pairs.count == 1)
        #expect(pairs[0].group == "X")
    }
}

// MARK: - Artist-aware album grouping

@Suite struct AlbumGroupTests {
    @Test func sameNameDifferentArtistsStaySeparate() {
        let g = groupAlbumVariants([(artist: "A", album: "Greatest Hits"),
                                    (artist: "B", album: "Greatest Hits")])
        #expect(g.count == 2)
        #expect(g[0].id != g[1].id)
    }

    @Test func variantsMergeWithinOneArtist() {
        let g = groupAlbumVariants([(artist: "Gamma Ray", album: "Blast [Disc 1]"),
                                    (artist: "Gamma Ray", album: "Blast [Disc 2]"),
                                    (artist: "Other", album: "Blast")])
        #expect(g.count == 2)
        #expect(g[0].base == "Blast")
        #expect(g[0].variants.count == 2)
        #expect(g[1].artist == "Other")
        #expect(g[1].variants == ["Blast"])
    }

    @Test func emptyArtistGroupsTogether() {
        let g = groupAlbumVariants([(artist: "", album: "X [Disc 1]"),
                                    (artist: "", album: "X [Disc 2]")])
        #expect(g.count == 1)
        #expect(g[0].variants.count == 2)
    }

    @Test func artistCaseInsensitiveKey() {
        let g = groupAlbumVariants([(artist: "ABBA", album: "Gold [Disc 1]"),
                                    (artist: "Abba", album: "Gold [Disc 2]")])
        #expect(g.count == 1)
    }
}

// MARK: - Duplicate library copies (artist-scoped)

@Suite struct DedupedAlbumTracksTests {
    private func song(file: String, title: String, track: String,
                      artist: String = "PT", albumArtist: String = "") -> MPDSong {
        var s = MPDSong()
        s.file = file; s.title = title; s.track = track
        s.artist = artist; s.albumArtist = albumArtist; s.album = "A"
        return s
    }

    @Test func duplicateCopiesOfSameArtistCollapse() {
        let deduped = dedupedAlbumTracks([
            song(file: "a/01.flac", title: "Fear of a Blank Planet", track: "1"),
            song(file: "b/01.flac", title: "Fear of a Blank Planet", track: "1"),
            song(file: "a/02.flac", title: "My Ashes", track: "2"),
            song(file: "b/02.flac", title: "MY ASHES", track: "2"),
        ])
        #expect(deduped.count == 2)
        #expect(deduped.map(\.file) == ["a/01.flac", "a/02.flac"])  // first wins
    }

    // The case that forced the earlier revert: same album name, same track
    // titles, DIFFERENT artists — nothing may collapse.
    @Test func sameTitlesAcrossArtistsAreKept() {
        let kept = dedupedAlbumTracks([
            song(file: "x/01.flac", title: "Intro", track: "1", artist: "Artist One"),
            song(file: "y/01.flac", title: "Intro", track: "1", artist: "Artist Two"),
        ])
        #expect(kept.count == 2)
    }

    @Test func albumArtistWinsOverArtistForTheKey() {
        // Compilation copies: per-song artists match, albumartist identical
        let kept = dedupedAlbumTracks([
            song(file: "x/01.flac", title: "Song", track: "1", artist: "Feat A", albumArtist: "Various"),
            song(file: "y/01.flac", title: "Song", track: "1", artist: "Feat A", albumArtist: "Various"),
        ])
        #expect(kept.count == 1)
    }

    @Test func differentTracksAndTitlesKept() {
        let kept = dedupedAlbumTracks([
            song(file: "1", title: "Song", track: "1"),
            song(file: "2", title: "Song", track: "2"),
            song(file: "3", title: "Other", track: "1"),
        ])
        #expect(kept.count == 3)
    }

    @Test func untitledFilesKeyOnFilename() {
        let kept = dedupedAlbumTracks([
            song(file: "a/one.flac", title: "", track: "0"),
            song(file: "a/two.flac", title: "", track: "0"),
        ])
        #expect(kept.count == 2)
    }
}

// MARK: - Token-overlap album matching

@Suite struct AlbumTokenMatchTests {
    @Test func decoratedTitleMatchesByTokens() {
        let ok = WikipediaService.albumResultMatches(
            title: "Live from the Beacon Theatre",
            extract: "Live from the Beacon Theatre is a live album recorded by Joe Bonamassa.",
            album: "Beacon Theatre. Live from...", artist: "Joe Bonamassa")
        #expect(ok)
    }

    @Test func unrelatedAlbumStillRejected() {
        let ok = WikipediaService.albumResultMatches(
            title: "Completely Different Record",
            extract: "An unrelated article about something else entirely by Joe Bonamassa.",
            album: "Beacon Theatre. Live from...", artist: "Joe Bonamassa")
        #expect(!ok)
    }

    @Test func wrongArtistStillRejected() {
        let ok = WikipediaService.albumResultMatches(
            title: "Live from the Beacon Theatre",
            extract: "Live from the Beacon Theatre is a live album by someone unrelated.",
            album: "Beacon Theatre. Live from...", artist: "Joe Bonamassa")
        #expect(!ok)
    }

    // A sequel's article cites the album by name in its extract, so the loose
    // check passes — fetchAlbum must therefore prefer hits whose *title* names
    // the album. titleMatchesAlbum is that discriminator.
    @Test func sequelTitleIsNotATitleMatch() {
        #expect(!WikipediaService.titleMatchesAlbum(
            title: "Live at Carnegie Hall: An Acoustic Evening",
            album: "An Acoustic Evening at the Vienna Opera House"))
    }

    @Test func ownArticleIsATitleMatch() {
        #expect(WikipediaService.titleMatchesAlbum(
            title: "An Acoustic Evening at the Vienna Opera House",
            album: "An Acoustic Evening at the Vienna Opera House"))
    }

    @Test func decoratedTagStillTitleMatchesByTokens() {
        #expect(WikipediaService.titleMatchesAlbum(
            title: "Live from the Beacon Theatre",
            album: "Beacon Theatre. Live from..."))
    }

    // "the" is a stopword and matching is word-level: {best, doors} vs
    // "The Doors (album)" is 1 of 2 hits — the debut album must not match.
    @Test func compilationDoesNotMatchDebutAlbum() {
        #expect(!WikipediaService.titleMatchesAlbum(
            title: "The Doors (album)", album: "Best of the Doors"))
        #expect(WikipediaService.titleMatchesAlbum(
            title: "The Best of the Doors", album: "Best of the Doors"))
    }

    @Test func stopwordDoesNotHitInsideWords() {
        // Substring matching would let "the" hit "theatre"
        #expect(!titleTokensMatch(candidate: "theatre and anderson", query: "the best songs"))
    }

    @Test func singleTokenAlbumsNeverTokenMatch() {
        // "101" is covered by exact containment, not by tokens
        #expect(!titleTokensMatch(candidate: "101 dalmatians", query: "101"))
    }

    // A related article mentioning most of the album's words in its extract
    // must no longer pass — the extract needs the exact album name.
    @Test func extractWordSoupIsRejected() {
        let ok = WikipediaService.albumResultMatches(
            title: "Ballads & Blues 1982",
            extract: "A Gary Moore compilation of his very best emerald-era blood-pumping songs, part two of a series.",
            album: "Blood of Emeralds - The Very Best of Gary Moore Part 2",
            artist: "Gary Moore")
        #expect(!ok)
    }

    @Test func exactExtractMentionStillMatches() {
        let ok = WikipediaService.albumResultMatches(
            title: "Gary Moore discography",
            extract: "Includes Blood of Emeralds - The Very Best of Gary Moore Part 2, released 1999 by Gary Moore.",
            album: "Blood of Emeralds - The Very Best of Gary Moore Part 2",
            artist: "Gary Moore")
        #expect(ok)
    }
}

// MARK: - Album variant grouping

@Suite struct GroupAlbumVariantsTests {
    @Test func groupsDiscVariants() {
        let g = groupAlbumVariants(["X [Disc 1]", "X [Disc 2]", "Y"])
        #expect(g.count == 2)
        #expect(g[0].base == "X")
        #expect(g[0].variants == ["X [Disc 1]", "X [Disc 2]"])
        #expect(g[1].base == "Y")
        #expect(g[1].variants == ["Y"])
    }

    @Test func preservesFirstAppearanceOrder() {
        let g = groupAlbumVariants(["B", "A [CD 2]", "A [CD 1]"])
        #expect(g.map(\.base) == ["B", "A"])
        #expect(g[1].variants == ["A [CD 2]", "A [CD 1]"])
    }

    @Test func prefixesDoNotMerge() {
        let g = groupAlbumVariants(["Foo", "Foobar"])
        #expect(g.count == 2)
    }

    @Test func plainAlbumsPassThrough() {
        let g = groupAlbumVariants(["One", "Two"])
        #expect(g.count == 2)
        #expect(g[0].variants == ["One"])
    }
}

// MARK: - Disc-aware sorting

@Suite struct DiscSortTests {
    private func song(album: String = "A", disc: String = "", track: String) -> MPDSong {
        var s = MPDSong()
        s.album = album; s.disc = disc; s.track = track
        s.file = "\(album)-\(disc)-\(track)"
        return s
    }

    @Test func discTagOrdersBeforeTrack() {
        let sorted = sortedByDiscAndTrack([
            song(disc: "2", track: "1"),
            song(disc: "1", track: "2"),
            song(disc: "1", track: "1"),
        ])
        #expect(sorted.map(\.track) == ["1", "2", "1"])
        #expect(sorted.map(\.discNumber) == [1, 1, 2])
    }

    @Test func discNumberParsesSlashFormat() {
        var s = MPDSong()
        s.disc = "1/2"
        #expect(s.discNumber == 1)
        s.disc = ""
        #expect(s.discNumber == 0)
    }

    @Test func effectiveDiscFallsBackToAlbumSuffix() {
        let sorted = sortedByDiscAndTrack([
            song(album: "X [Disc 2]", track: "1"),
            song(album: "X [Disc 1]", track: "1"),
        ])
        #expect(sorted.map(\.album) == ["X [Disc 1]", "X [Disc 2]"])
        #expect(sorted.map(\.effectiveDisc) == [1, 2])
    }

    @Test func discTagWinsOverSuffix() {
        var s = MPDSong()
        s.album = "X [Disc 2]"
        s.disc = "3"
        #expect(s.effectiveDisc == 3)
    }

    @Test func discParsedFromRecord() {
        let s = MPDSong(["file": "f", "disc": "2"])
        #expect(s.disc == "2")
        #expect(s.discNumber == 2)
    }
}

// MARK: - Snapcast tests

nonisolated(unsafe) private let snapStatusFixture: [String: Any] = [
    "groups": [
        [
            "id": "group-1",
            "name": "Downstairs",
            "muted": false,
            "stream_id": "default",
            "clients": [
                [
                    "id": "aa:bb:cc:dd:ee:ff",
                    "connected": true,
                    "host": ["name": "pi-living"],
                    "config": [
                        "name": "Living Room",
                        "latency": 50,
                        "volume": ["percent": 85, "muted": false]
                    ]
                ],
                [
                    "id": "11:22:33:44:55:66",
                    "connected": false,
                    "host": ["name": "desktop"],
                    "config": [
                        "name": "",     // falls back to hostName
                        "volume": ["percent": 50, "muted": true]
                    ]
                ]
            ]
        ]
    ],
    "server": [:],
    "streams": [
        ["id": "default", "status": "playing"],
        ["id": "optical", "status": "idle"]
    ]
]

@Suite struct SnapcastModelTests {
    @Test func decodeGroupsFromFixture() {
        let groups = decodeSnapGroups(from: snapStatusFixture)
        #expect(groups.count == 1)
        let g = groups[0]
        #expect(g.id == "group-1")
        #expect(g.name == "Downstairs")
        #expect(g.muted == false)
        #expect(g.streamID == "default")
        #expect(g.clients.count == 2)
    }

    @Test func connectedClientParsed() {
        let client = decodeSnapGroups(from: snapStatusFixture)[0].clients[0]
        #expect(client.id == "aa:bb:cc:dd:ee:ff")
        #expect(client.connected == true)
        #expect(client.name == "Living Room")
        #expect(client.hostName == "pi-living")
        #expect(client.displayName == "Living Room")   // name wins
        #expect(client.volume.percent == 85)
        #expect(client.volume.muted == false)
        #expect(client.latency == 50)
    }

    @Test func clientLatencyDefaultsToZero() {
        let client = decodeSnapGroups(from: snapStatusFixture)[0].clients[1]
        #expect(client.latency == 0)    // no latency key in fixture for disconnected client
    }

    @Test func disconnectedClientDisplayNameFallsBackToHost() {
        let client = decodeSnapGroups(from: snapStatusFixture)[0].clients[1]
        #expect(client.connected == false)
        #expect(client.name == "")
        #expect(client.displayName == "desktop")       // hostName fallback
        #expect(client.volume.muted == true)
    }

    @Test func emptyGroupsWhenKeyMissing() {
        #expect(decodeSnapGroups(from: ["server": [:]]).isEmpty)
    }

    @Test func groupDisplayNameFallsBackToStreamID() {
        let json: [String: Any] = ["groups": [
            ["id": "g1", "name": "", "muted": false, "stream_id": "stream1", "clients": []]
        ]]
        let g = decodeSnapGroups(from: json)[0]
        #expect(g.displayName == "stream1")
    }
}

@Suite struct SnapcastWireTests {
    @Test func requestDataIncludesMethod() throws {
        let data = try snapcastRequestData(method: "Client.SetVolume",
                                           params: ["id": "aa", "volume": ["percent": 80, "muted": false]],
                                           id: 3)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["jsonrpc"] as? String == "2.0")
        #expect(json["method"] as? String == "Client.SetVolume")
        #expect(json["id"] as? Int == 3)
        let volume = (json["params"] as? [String: Any])?["volume"] as? [String: Any]
        #expect(volume?["percent"] as? Int == 80)
    }

    @Test func requestIDsIncrement() throws {
        let d1 = try snapcastRequestData(method: "M", params: [:], id: 1)
        let d2 = try snapcastRequestData(method: "M", params: [:], id: 2)
        let j1 = try JSONSerialization.jsonObject(with: d1) as! [String: Any]
        let j2 = try JSONSerialization.jsonObject(with: d2) as! [String: Any]
        #expect(j1["id"] as? Int == 1)
        #expect(j2["id"] as? Int == 2)
    }

    @Test func findResponseSkipsNotifications() {
        let notification = #"{"jsonrpc":"2.0","method":"Client.OnVolumeChanged","params":{"id":"x","volume":{"percent":50,"muted":false}}}"#
        let response     = #"{"jsonrpc":"2.0","id":3,"result":{"percent":80,"muted":false}}"#
        let wrong        = #"{"jsonrpc":"2.0","id":2,"result":{}}"#
        let lines = [notification, wrong, response]
        let found = snapcastFindResponse(in: lines, id: 3)
        #expect(found != nil)
        #expect(found?["id"] as? Int == 3)
    }

    @Test func findResponseReturnsNilWhenAbsent() {
        let notification = #"{"jsonrpc":"2.0","method":"Server.OnUpdate","params":{}}"#
        #expect(snapcastFindResponse(in: [notification], id: 1) == nil)
    }
}

@Suite struct SnapcastProfileCodableTests {
    @Test func legacyProfileDecodesWithDefaults() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Home","host":"192.168.1.1","port":6600,"streamURL":"","lastPartition":""}
        """
        let profile = try JSONDecoder().decode(MPDServerProfile.self, from: Data(legacy.utf8))
        #expect(profile.host == "192.168.1.1")
        #expect(profile.snapcastHost == "")
        #expect(profile.snapcastPort == 1705)
    }

    @Test func roundtripPreservesSnapcastFields() throws {
        var p = MPDServerProfile(name: "Test", host: "10.0.0.1")
        p.snapcastHost = "10.0.0.2"
        p.snapcastPort = 1706
        let data = try JSONEncoder().encode(p)
        let p2 = try JSONDecoder().decode(MPDServerProfile.self, from: data)
        #expect(p2.snapcastHost == "10.0.0.2")
        #expect(p2.snapcastPort == 1706)
    }
}

@Suite struct RelativeDayTests {
    private func date(daysAgo: Int, now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
    }

    @Test func today() { #expect(relativeDay(date(daysAgo: 0)) == "Today") }
    @Test func yesterday() { #expect(relativeDay(date(daysAgo: 1)) == "Yesterday") }
    @Test func twoDaysAgo() { #expect(relativeDay(date(daysAgo: 2)) == "2 days ago") }
    @Test func tenDaysAgo() { #expect(relativeDay(date(daysAgo: 10)) == "10 days ago") }
    @Test func explicitNow() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        #expect(relativeDay(yesterday, now: now) == "Yesterday")
    }
}

@Suite struct RecentAlbumGroupTests {
    private func entry(file: String = "f", title: String = "T", artist: String = "A",
                       album: String = "X", ago: TimeInterval = 0) -> RecentlyPlayedEntry {
        RecentlyPlayedEntry(file: file, title: title, artist: artist, album: album,
                            playedAt: Date(timeIntervalSinceReferenceDate: 1000 - ago))
    }

    @Test func dedupesSameAlbum() {
        let entries = [entry(title: "T1", ago: 0), entry(title: "T2", ago: 60)]
        let result = recentAlbumGroups(entries)
        #expect(result.count == 1)
        #expect(result[0].album == "X")
    }

    @Test func newestEntryWins() {
        let entries = [entry(title: "T1", ago: 0), entry(title: "T2", ago: 60)]
        let result = recentAlbumGroups(entries)
        // first entry in the input (newest) should be the representative
        #expect(result[0].lastPlayed == entries[0].playedAt)
    }

    @Test func discVariantsCollapse() {
        let entries = [entry(album: "X [Disc 1]", ago: 0), entry(album: "X [Disc 2]", ago: 60)]
        let result = recentAlbumGroups(entries)
        #expect(result.count == 1)
    }

    @Test func sameAlbumDifferentArtistsStaySeparate() {
        let entries = [
            entry(file: "f1", artist: "Artist A", album: "Hits", ago: 0),
            entry(file: "f2", artist: "Artist B", album: "Hits", ago: 60),
        ]
        let result = recentAlbumGroups(entries)
        #expect(result.count == 2)
    }

    @Test func albumlessTilesGroupByFile() {
        let entries = [
            entry(file: "http://radio.example.com/stream", title: "Radio", artist: "Station", album: "", ago: 0),
            entry(file: "http://radio.example.com/stream", title: "Radio", artist: "Station", album: "", ago: 60),
        ]
        let result = recentAlbumGroups(entries)
        #expect(result.count == 1)
        #expect(result[0].albumless == true)
        #expect(result[0].title == "Radio")
    }

    @Test func albumlessTilesPreserveTitle() {
        let e = entry(file: "loose.flac", title: "Untitled", artist: "", album: "")
        let result = recentAlbumGroups([e])
        #expect(result[0].albumless == true)
        #expect(result[0].title == "Untitled")
    }

    @Test func newestFirst() {
        let entries = [
            entry(file: "f1", album: "Alpha", ago: 0),
            entry(file: "f2", album: "Beta", ago: 60),
            entry(file: "f3", album: "Gamma", ago: 120),
        ]
        let result = recentAlbumGroups(entries)
        #expect(result.map(\.album) == ["Alpha", "Beta", "Gamma"])
    }

    @Test func emptyInput() {
        #expect(recentAlbumGroups([]).isEmpty)
    }

    @Test func idEqualsArtCacheKey() {
        let e = entry(artist: "Artist", album: "Album")
        let result = recentAlbumGroups([e])
        #expect(result[0].id == artCacheKey(artist: "Artist", album: "Album"))
    }
}

// MARK: - Snapcast stream tests

@Suite struct SnapStreamTests {
    @Test func decodeTwoStreamsFromFixture() {
        let streams = decodeSnapStreams(from: snapStatusFixture)
        #expect(streams.count == 2)
        #expect(streams[0].id == "default")
        #expect(streams[0].status == "playing")
        #expect(streams[1].id == "optical")
        #expect(streams[1].status == "idle")
    }

    @Test func emptyStreamsArray() {
        let fixture: [String: Any] = ["groups": [], "streams": [], "server": [:]]
        #expect(decodeSnapStreams(from: fixture).isEmpty)
    }

    @Test func missingStreamsKeyReturnsEmpty() {
        #expect(decodeSnapStreams(from: ["groups": []]).isEmpty)
    }

    @Test func streamStatusDefaultsToUnknown() {
        let fixture: [String: Any] = ["streams": [["id": "test"]]]
        let s = decodeSnapStreams(from: fixture)
        #expect(s[0].status == "unknown")
    }
}

// MARK: - Snapcast command payload tests

@Suite struct SnapcastCommandPayloadTests {
    @Test func setLatencyPayload() throws {
        let data = try snapcastRequestData(method: "Client.SetLatency",
                                           params: ["id": "aa:bb", "latency": 100], id: 1)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["method"] as? String == "Client.SetLatency")
        let p = json["params"] as? [String: Any]
        #expect(p?["id"] as? String == "aa:bb")
        #expect(p?["latency"] as? Int == 100)
    }

    @Test func setNamePayload() throws {
        let data = try snapcastRequestData(method: "Client.SetName",
                                           params: ["id": "aa:bb", "name": "Kitchen"], id: 2)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["method"] as? String == "Client.SetName")
        let p = json["params"] as? [String: Any]
        #expect(p?["name"] as? String == "Kitchen")
    }

    @Test func deleteClientPayload() throws {
        let data = try snapcastRequestData(method: "Server.DeleteClient",
                                           params: ["id": "aa:bb"], id: 3)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["method"] as? String == "Server.DeleteClient")
        #expect((json["params"] as? [String: Any])?["id"] as? String == "aa:bb")
    }

    @Test func setGroupStreamPayload() throws {
        let data = try snapcastRequestData(method: "Group.SetStream",
                                           params: ["id": "group-1", "stream_id": "optical"], id: 4)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["method"] as? String == "Group.SetStream")
        let p = json["params"] as? [String: Any]
        #expect(p?["id"] as? String == "group-1")
        #expect(p?["stream_id"] as? String == "optical")
    }

    @Test func setGroupClientsPayload() throws {
        let clients = ["aa:bb:cc", "11:22:33"]
        let data = try snapcastRequestData(method: "Group.SetClients",
                                           params: ["id": "group-1", "clients": clients], id: 5)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["method"] as? String == "Group.SetClients")
        let p = json["params"] as? [String: Any]
        #expect(p?["id"] as? String == "group-1")
        #expect((p?["clients"] as? [String]) == clients)
    }
}
