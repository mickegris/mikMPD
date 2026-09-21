// SongCatalogTests.swift
// Library → Songs (issue #14). MPD's own `sort Title` is byte order, so A–Z,
// its sections and the paged walk are all the app's — and all pure, tested here.
// Titles below are real ones from the library MPD sorted wrongly.
import Testing
import Foundation
@testable import mikMPD

private let en = Locale(identifier: "en_US")
private let sv = Locale(identifier: "sv_SE")

private func song(_ title: String, artist: String = "", album: String = "", file: String? = nil) -> MPDSong {
    var r: MPDRecord = ["file": file ?? "\(artist)/\(title).flac"]
    if !title.isEmpty { r["title"] = title }
    if !artist.isEmpty { r["artist"] = artist }
    if !album.isEmpty { r["album"] = album }
    return MPDSong(r)
}

private func titles(_ list: [CatalogSong]) -> [String] { list.map(\.song.displayTitle) }

@Suite struct SongTitleSortKeyTests {
    @Test func leadingPunctuationIsIgnored() {
        #expect(songTitleSortKey("“Heroes”") == "Heroes”")
        #expect(songTitleSortKey("…and Justice for All") == "and Justice for All")
        #expect(songTitleSortKey("...And the Mouse Police Never Sleeps") == "And the Mouse Police Never Sleeps")
        #expect(songTitleSortKey("(Don't Fear) The Reaper") == "Don't Fear) The Reaper")
        #expect(songTitleSortKey("''LOA'' House") == "LOA'' House")
    }

    @Test func digitsAndTheAreKept() {
        #expect(songTitleSortKey("'39") == "39")
        #expect(songTitleSortKey("The Wait") == "The Wait")
    }

    /// A title of punctuation only must still sort somewhere, not vanish.
    @Test func allPunctuationFallsBackToTheTitle() {
        #expect(songTitleSortKey("?!") == "?!")
    }
}

@Suite struct SortedCatalogTests {
    /// MPD put every lowercase title after Z; A–Z must ignore case.
    @Test func caseDoesNotSplitTheAlphabet() {
        let list = sortedCatalog([song("whiskey in the jar"), song("Blitzkrieg"),
                                  song("am i evil?"), song("Zero")], locale: en)
        #expect(titles(list) == ["am i evil?", "Blitzkrieg", "whiskey in the jar", "Zero"])
    }

    @Test func mixedCaseDuplicatesSortTogether() {
        let list = sortedCatalog([song("Another Stranger Me"),
                                  song("Another Brick in the Wall (Part 2)"),
                                  song("Another Brick In The Wall, Pt. 3")], locale: en)
        #expect(titles(list) == ["Another Brick in the Wall (Part 2)",
                                 "Another Brick In The Wall, Pt. 3", "Another Stranger Me"])
    }

    /// In Swedish, Å Ä Ö are letters after Z; in English they sort with A and O.
    @Test func swedishLettersFollowTheLocale() {
        let songs = [song("Ölstugan som inte finns"), song("Zombie"), song("Åtta Dygn I Kolet"),
                     song("Älska mej Bill"), song("Anna")]
        #expect(titles(sortedCatalog(songs, locale: sv)) ==
                ["Anna", "Zombie", "Åtta Dygn I Kolet", "Älska mej Bill", "Ölstugan som inte finns"])
        // English treats Ä as a: "Äl" before "An".
        #expect(titles(sortedCatalog(songs, locale: en)) ==
                ["Älska mej Bill", "Anna", "Åtta Dygn I Kolet", "Ölstugan som inte finns", "Zombie"])
    }

    @Test func numbersSortNumerically() {
        let list = sortedCatalog([song("Track 10"), song("Track 2")], locale: en)
        #expect(titles(list) == ["Track 2", "Track 10"])
    }

    @Test func punctuatedTitlesFileUnderTheirWord() {
        let list = sortedCatalog([song("Iron Man"), song("“Heroes”"), song("Help!")], locale: en)
        #expect(titles(list) == ["Help!", "“Heroes”", "Iron Man"])
    }

    /// Four copies of one title: a total order, so a reload never reshuffles.
    @Test func tiesBreakByArtistThenFile() {
        let list = sortedCatalog([
            song("The Reaper", artist: "Blue Öyster Cult", file: "b/2.flac"),
            song("The Reaper", artist: "Apollo", file: "z.flac"),
            song("The Reaper", artist: "Blue Öyster Cult", file: "b/1.flac"),
        ], locale: en)
        #expect(list.map(\.song.file) == ["z.flac", "b/1.flac", "b/2.flac"])
    }

    /// An untitled file sorts by its filename, not as an empty string at one end.
    @Test func untitledSortsByFilename() {
        let list = sortedCatalog([song("Middle"), song("", file: "dir/Zulu.mp3"),
                                  song("", file: "dir/Alpha.mp3")], locale: en)
        #expect(titles(list) == ["Alpha.mp3", "Middle", "Zulu.mp3"])
    }
}

@Suite struct SongSectionLabelTests {
    @Test func asciiLettersAreThemselves() {
        #expect(songSectionLabel(for: "a", locale: en) == "A")
        #expect(songSectionLabel(for: "Z", locale: en) == "Z")
    }

    @Test func nonLettersAreHash() {
        #expect(songSectionLabel(for: "3", locale: en) == "#")
        #expect(songSectionLabel(for: "'", locale: en) == "#")
    }

    @Test func accentedLettersJoinTheirBaseLetter() {
        #expect(songSectionLabel(for: "É", locale: en) == "E")
        #expect(songSectionLabel(for: "é", locale: en) == "E")
        #expect(songSectionLabel(for: "Å", locale: en) == "A")
        #expect(songSectionLabel(for: "Ö", locale: en) == "O")
        #expect(songSectionLabel(for: "Æ", locale: en) == "A")
        #expect(songSectionLabel(for: "Ž", locale: en) == "Z")
    }

    @Test func swedishLettersAreTheirOwnSections() {
        #expect(songSectionLabel(for: "Å", locale: sv) == "Å")
        #expect(songSectionLabel(for: "ä", locale: sv) == "Ä")
        #expect(songSectionLabel(for: "Ö", locale: sv) == "Ö")
        #expect(songSectionLabel(for: "É", locale: sv) == "E")
    }

    @Test func nonLatinScriptsAreHash() {
        #expect(songSectionLabel(for: "荒", locale: en) == "#")
        #expect(songSectionLabel(for: "Ж", locale: en) == "#")
    }
}

@Suite struct SongSectionsTests {
    private let songs = [song("Zombie"), song("Älska mej Bill"), song("Anna"), song("'39"),
                         song("Åtta Dygn I Kolet"), song("Ölstugan"), song("Blitzkrieg"),
                         song("荒城の月"), song("Écoute")]

    private func labels(_ s: [SongSection]) -> [String] { s.map(\.label) }

    @Test func swedishSectionsFollowTheSort() {
        let sections = songSections(sortedCatalog(songs, locale: sv), locale: sv)
        #expect(labels(sections) == ["#", "A", "B", "E", "Z", "Å", "Ä", "Ö", "#"])
        #expect(Set(sections.map(\.id)).count == sections.count)
    }

    @Test func englishSectionsFoldAccents() {
        let sections = songSections(sortedCatalog(songs, locale: en), locale: en)
        #expect(labels(sections) == ["#", "A", "B", "E", "O", "Z", "#"])
        #expect(sections.first { $0.label == "A" }?.songs.count == 3)
    }

    /// Every song lands in exactly one section, in list order.
    @Test func sectionsPartitionTheList() {
        let sorted = sortedCatalog(songs, locale: sv)
        #expect(songSections(sorted, locale: sv).flatMap(\.songs) == sorted)
    }

    @Test func emptyListHasNoSections() {
        #expect(songSections([], locale: en).isEmpty)
    }
}

@Suite struct DisplayedCatalogTests {
    private let sorted = sortedCatalog([song("Anna", artist: "Abba", album: "Arrival"),
                                        song("Breadfan", artist: "Metallica", album: "Garage Inc."),
                                        song("Crash", artist: "Ramones", album: "Road to Ruin")],
                                       locale: en)

    @Test func zToAIsReversed() {
        #expect(titles(displayedCatalog(sorted, filter: "", sort: .za)) == ["Crash", "Breadfan", "Anna"])
        let sections = songSections(displayedCatalog(sorted, filter: "", sort: .za), locale: en)
        #expect(sections.map(\.label) == ["C", "B", "A"])
    }

    @Test func filterMatchesTitleArtistOrAlbum() {
        #expect(titles(displayedCatalog(sorted, filter: "crash", sort: .az)) == ["Crash"])
        #expect(titles(displayedCatalog(sorted, filter: "metal", sort: .az)) == ["Breadfan"])
        #expect(titles(displayedCatalog(sorted, filter: "arrival", sort: .az)) == ["Anna"])
        #expect(displayedCatalog(sorted, filter: "  ", sort: .az).count == 3)
    }

    /// "Road" is in an album name only; scoped to Title it matches nothing.
    @Test func scopeLimitsTheField() {
        #expect(titles(displayedCatalog(sorted, filter: "road", scope: .album, sort: .az)) == ["Crash"])
        #expect(displayedCatalog(sorted, filter: "road", scope: .title, sort: .az).isEmpty)
        #expect(displayedCatalog(sorted, filter: "road", scope: .artist, sort: .az).isEmpty)
        #expect(titles(displayedCatalog(sorted, filter: "abba", scope: .artist, sort: .az)) == ["Anna"])
        #expect(titles(displayedCatalog(sorted, filter: "anna", scope: .title, sort: .az)) == ["Anna"])
    }

    /// A compilation track is found by its album artist as well as its own.
    @Test func artistScopeMatchesAlbumArtist() {
        let s = MPDSong(["file": "va/1.flac", "title": "Street Life", "artist": "Randy Crawford",
                         "albumartist": "Various Artists", "album": "Jackie Brown"])
        let list = sortedCatalog([s], locale: en)
        #expect(displayedCatalog(list, filter: "various", scope: .artist, sort: .az).count == 1)
        #expect(displayedCatalog(list, filter: "crawford", scope: .artist, sort: .az).count == 1)
    }
}

@Suite struct SongCatalogWalkerTests {
    private func page(_ range: Range<Int>) -> [MPDSong] {
        range.map { song("T\($0)", file: "f\($0)") }
    }

    @Test func emptyLibraryFetchesNothing() {
        #expect(SongCatalogWalker(total: 0, pageSize: 10).firstStep == .done)
    }

    @Test func walksPagesUntilTheTotal() {
        var w = SongCatalogWalker(total: 25, pageSize: 10)
        #expect(w.firstStep == .fetch(start: 0, end: 10))
        #expect(w.accept(page: page(0..<10)) == .fetch(start: 10, end: 20))
        #expect(w.accept(page: page(10..<20)) == .fetch(start: 20, end: 30))
        #expect(w.accept(page: page(20..<25)) == .done)
        #expect(w.songs.count == 25)
    }

    /// A total that is an exact multiple of the page size needs no empty page.
    @Test func exactMultipleStopsAtTheTotal() {
        var w = SongCatalogWalker(total: 20, pageSize: 10)
        _ = w.accept(page: page(0..<10))
        #expect(w.accept(page: page(10..<20)) == .done)
    }

    /// Songs removed mid-walk end it early and trigger one recount.
    @Test func shortPageWithMissingSongsRecountsOnce() {
        var w = SongCatalogWalker(total: 25, pageSize: 10)
        _ = w.accept(page: page(0..<10))
        #expect(w.accept(page: page(10..<13)) == .recount)
        #expect(w.restart(total: 13) == .fetch(start: 0, end: 10))
        #expect(w.songs.isEmpty)
        _ = w.accept(page: page(0..<10))
        #expect(w.accept(page: page(10..<13)) == .done)
        #expect(w.songs.count == 13)
    }

    /// A second mismatch is accepted rather than looping.
    @Test func recountsAtMostOnce() {
        var w = SongCatalogWalker(total: 5, pageSize: 10)
        #expect(w.accept(page: page(0..<3)) == .recount)
        _ = w.restart(total: 5)
        #expect(w.accept(page: page(0..<3)) == .done)
        #expect(w.songs.count == 3)
    }

    /// A shifted page repeats URIs; they appear once.
    @Test func duplicateURIsAreDropped() {
        var w = SongCatalogWalker(total: 20, pageSize: 10)
        _ = w.accept(page: page(0..<10))
        _ = w.accept(page: page(8..<18))
        #expect(w.songs.count == 18)
        #expect(Set(w.songs.map(\.file)).count == 18)
    }

    /// An embedded CUE sheet adds a file-less `playlist:` record, which is not
    /// a song: it must neither be listed nor make a short page look full.
    @Test func fileLessRecordsAreNotSongs() {
        var w = SongCatalogWalker(total: 30, pageSize: 10)
        let cue = MPDSong(["playlist": "album.flac/album.cue"])
        #expect(w.accept(page: page(0..<9) + [cue]) == .recount)
        #expect(w.songs.count == 9)
    }

    @Test func stopsAtTheLimit() {
        var w = SongCatalogWalker(total: 30, pageSize: 10, limit: 15)
        _ = w.accept(page: page(0..<10))
        #expect(w.accept(page: page(10..<20)) == .done)
        #expect(w.songs.count == 15)
    }
}
