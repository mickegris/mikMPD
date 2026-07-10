import Foundation
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
