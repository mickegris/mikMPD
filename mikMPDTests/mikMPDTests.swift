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
