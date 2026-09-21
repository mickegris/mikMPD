// SongCatalog.swift
// Library → Songs: every track in the database, A–Z by title (issue #14).
//
// Three facts shape this file, each measured on a real server:
//
// 1. **MPD cannot hand over the whole library in one response.** A response
//    larger than `max_output_buffer_size` (8 MiB by default, 0.21 included)
//    makes MPD close the connection; the app would see an I/O error, reconnect,
//    and ask again. The protocol docs say of `listallinfo`: "It will break with
//    large databases." So the songs arrive in pages of `find … window`, one
//    page per `Q.async`, so the poll and the user's commands run in between.
//
// 2. **MPD's own `sort Title` is byte order**, on 0.24 as well as 0.21: in a
//    real 10 k-song library, 40 lowercase titles sorted after Z, every Å/Ä/Ö
//    title after those, and "In The Wall" before "in the Wall". A–Z is
//    therefore the app's job, done once per load, off the main thread.
//
// 3. **Pages are not sorted at all.** Without `sort` the order is the database
//    walk, which is what `findadd` ordering already relies on; the walk is not
//    trusted blindly — URIs are deduplicated and the total is checked against
//    `count`, with one recount if the library changed mid-walk.
//
// Only MPD 0.21 syntax is used (filter expressions, `window`, `count`), so the
// path tested here is the path an older server such as a Chord Poly runs.
import SwiftUI
import Combine

/// Largest library the Songs list will load: ~35 MiB of transfer at the
/// measured ~350 bytes per song. Beyond it the view points to Search instead.
nonisolated let songCatalogLimit = 100_000

/// Songs per `find … window` page: ~350 KiB, far below MPD's 8 MiB buffer.
nonisolated let songCatalogPageSize = 1000

/// The filter that matches every song, in 0.21 filter-expression syntax.
/// (`file` routes to MPD's URI filter; `!=` is accepted since 0.21.)
nonisolated let songCatalogFilter = "(file != '')"

/// Song count for the whole library. An ACK means MPD older than 0.21.
nonisolated let songCatalogCountCommand = "count \"\(songCatalogFilter.esc)\""

/// One page of the walk. No `sort`: MPD's is byte order (see above), and it
/// would re-sort the whole library for every page.
nonisolated func songCatalogPageCommand(start: Int, end: Int) -> String {
    "find \"\(songCatalogFilter.esc)\" window \(start):\(end)"
}

// MARK: - Pure logic

/// One row of the Songs list: the song and its precomputed sort key.
nonisolated struct CatalogSong: Identifiable, Equatable, Sendable {
    let song: MPDSong
    let sortKey: String
    var id: String { song.file }
}

/// What a title is sorted by: the displayed title (the filename when the Title
/// tag is missing, so untagged files do not pile up at one end) with leading
/// punctuation dropped, so `“Heroes”` files under H and `…And Justice for All`
/// under A. A leading "The" is kept, as in the Artists list.
nonisolated func songTitleSortKey(_ title: String) -> String {
    let stripped = String(title.drop { !$0.isLetter && !$0.isNumber })
    return stripped.isEmpty ? title : stripped
}

/// The comparison behind A–Z: case-insensitive, digit-aware ("Track 2" before
/// "Track 10") and locale-aware (in Swedish, Å Ä Ö come after Z). The same
/// options as `localizedStandardCompare`, with the locale injectable for tests.
nonisolated func songTitleCompare(_ a: String, _ b: String, locale: Locale) -> ComparisonResult {
    a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering],
              range: nil, locale: locale)
}

/// Sorts once, A–Z. Keys are computed once per song, never in the comparator.
/// Ties are broken by artist, then URI, so the order is total and a reload
/// never shuffles songs that share a title.
nonisolated func sortedCatalog(_ songs: [MPDSong], locale: Locale = .current) -> [CatalogSong] {
    songs.map { CatalogSong(song: $0, sortKey: songTitleSortKey($0.displayTitle)) }
        .sorted { a, b in
            switch songTitleCompare(a.sortKey, b.sortKey, locale: locale) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            case .orderedSame:
                switch songTitleCompare(a.song.displayArtist, b.song.displayArtist, locale: locale) {
                case .orderedAscending:  return true
                case .orderedDescending: return false
                case .orderedSame:       return a.song.file < b.song.file
                }
            }
        }
}

/// The section-index letter for a sort key's first character.
///
/// ASCII letters are their own section. Anything that is not a letter is `#`.
/// Any other letter goes under the ASCII letter the *locale* sorts it with —
/// `É` under E, and in English `Å` under A — or, when the locale sorts it after
/// Z (Swedish Å Ä Ö), becomes its own section if it is a Latin letter and `#`
/// if not (CJK, Cyrillic …). Deciding by the comparator, not by folding
/// diacritics, is what keeps the section order in step with the sort order.
nonisolated func songSectionLabel(for ch: Character, locale: Locale) -> String {
    guard ch.isLetter else { return "#" }
    let up = String(ch).uppercased()
    if up.unicodeScalars.count == 1, let s = up.unicodeScalars.first, s.isASCII { return up }
    var bucket: String?
    for v in UInt8(ascii: "A")...UInt8(ascii: "Z") {
        let letter = String(UnicodeScalar(v))
        if songTitleCompare(letter, up, locale: locale) == .orderedDescending { break }
        bucket = letter
    }
    // "Z" as the bucket means "sorts at or after Z" — only a real Z-variant (Ž)
    // belongs there; a letter sorting after the whole alphabet does not.
    if let bucket, bucket != "Z" || songTitleCompare(up, "ZZ", locale: locale) == .orderedAscending {
        return bucket
    }
    let latin = up.unicodeScalars.allSatisfy { (0x00C0...0x024F).contains($0.value) || (0x1E00...0x1EFF).contains($0.value) }
    return latin ? up : "#"
}

/// A run of consecutive songs sharing a section label.
nonisolated struct SongSection: Identifiable, Equatable, Sendable {
    /// Unique even if a label recurs non-adjacently (locale oddities): the
    /// position of the run, not the label.
    let id: Int
    let label: String
    let songs: [CatalogSong]
}

/// Sections by walking the list in display order and starting a new section
/// whenever the label changes — derived from the sort, never assumed, so the
/// sections always come out in the order the songs do.
nonisolated func songSections(_ songs: [CatalogSong], locale: Locale = .current) -> [SongSection] {
    var cache: [Character: String] = [:]
    var out: [SongSection] = []
    var label = "", run: [CatalogSong] = []
    for s in songs {
        let l: String
        if let ch = s.sortKey.first {
            if let hit = cache[ch] { l = hit }
            else { l = songSectionLabel(for: ch, locale: locale); cache[ch] = l }
        } else { l = "#" }
        if l != label, !run.isEmpty {
            out.append(SongSection(id: out.count, label: label, songs: run)); run = []
        }
        label = l; run.append(s)
    }
    if !run.isEmpty { out.append(SongSection(id: out.count, label: label, songs: run)) }
    return out
}

/// The list as shown: filtered on the scope's field(s) and in the chosen
/// direction. Z–A is the A–Z list reversed. Artist matches either credit
/// (`displayArtist` or `groupingArtist`), so a compilation track is found by
/// its own artist and by the album artist.
nonisolated func displayedCatalog(_ sorted: [CatalogSong], filter: String,
                                  scope: SongFilterScope = .all, sort: SongSort) -> [CatalogSong] {
    let q = filter.trimmingCharacters(in: .whitespaces)
    func title(_ s: MPDSong) -> Bool { s.displayTitle.localizedCaseInsensitiveContains(q) }
    func artist(_ s: MPDSong) -> Bool {
        s.displayArtist.localizedCaseInsensitiveContains(q) || s.groupingArtist.localizedCaseInsensitiveContains(q)
    }
    func album(_ s: MPDSong) -> Bool { s.album.localizedCaseInsensitiveContains(q) }
    let filtered = q.isEmpty ? sorted : sorted.filter {
        switch scope {
        case .all:    title($0.song) || artist($0.song) || album($0.song)
        case .title:  title($0.song)
        case .artist: artist($0.song)
        case .album:  album($0.song)
        }
    }
    return sort == .az ? filtered : filtered.reversed()
}

/// The page walk as a state machine, so the store can issue each page from its
/// own `Q.async` and tests can drive it without a server.
nonisolated struct SongCatalogWalker {
    enum Step: Equatable {
        case fetch(start: Int, end: Int)
        /// The walk ended with a different number of songs than `count` said:
        /// the library changed underneath. Count again and start over — once.
        case recount
        case done
    }

    let pageSize: Int
    let limit: Int
    private(set) var total: Int
    private(set) var songs: [MPDSong] = []
    private(set) var hasRecounted = false
    private var seen: Set<String> = []
    private var next = 0

    init(total: Int, pageSize: Int = songCatalogPageSize, limit: Int = songCatalogLimit) {
        self.total = total; self.pageSize = pageSize; self.limit = limit
    }

    var firstStep: Step { total > 0 ? .fetch(start: 0, end: pageSize) : .done }

    mutating func accept(page: [MPDSong]) -> Step {
        // `window` counts songs; a CUE sheet adds a `playlist:` record with no
        // file, which is not a song and must not make a short page look full.
        let pageSongs = page.filter { !$0.file.isEmpty }
        for s in pageSongs where seen.insert(s.file).inserted { songs.append(s) }
        next += pageSize
        if songs.count >= limit {
            songs = Array(songs.prefix(limit))
            return .done
        }
        if pageSongs.count < pageSize || next >= total {
            return songs.count != total && !hasRecounted ? .recount : .done
        }
        return .fetch(start: next, end: next + pageSize)
    }

    mutating func restart(total newTotal: Int) -> Step {
        hasRecounted = true
        total = newTotal; songs = []; seen = []; next = 0
        return firstStep
    }
}

// MARK: - Observable state

/// The Songs list's state, kept out of `MPDStore` for the same reason as
/// `PlaybackClock`: progress changes once per page, and the store's single
/// `objectWillChange` would re-render every view observing it. Only the Songs
/// view observes this.
///
/// Cached per server *and* database version (`stats`' `db_update`), not per
/// connection: `connect()` runs on every foreground resume, and the library
/// does not change because the phone was unlocked. Checking `db_update` on each
/// visit costs one small command and also catches scans made by other clients
/// or while the app was in the background.
@MainActor
final class SongCatalog: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading(loaded: Int, total: Int)
        case loaded
        case tooLarge(Int)
        case unsupported
        case failed(String)
    }

    enum Outcome: Sendable {
        case loaded([CatalogSong], key: String)
        case unchanged
        case tooLarge(Int)
        case unsupported
        case failed(String)
        case abandoned
    }

    @Published private(set) var phase: Phase = .idle
    /// A–Z. Views derive their filtered/reversed sections from this.
    @Published private(set) var songs: [CatalogSong] = []
    /// Bumped whenever `songs` is replaced — cheaper to watch than the array.
    @Published private(set) var revision = 0

    /// `serverID|db_update` of the loaded list.
    private(set) var loadedKey: String?
    private(set) var isLoading = false
    private var token = 0
    private var viewers = 0
    private var memoryObserver: NSObjectProtocol?

    init() {
        // A list nobody is looking at is the first thing to give back.
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.viewers == 0, !self.isLoading else { return }
                self.reset()
            }
        }
    }

    func attach() { viewers += 1 }
    func detach() { viewers = max(0, viewers - 1) }

    /// Starts a load; returns its token, or nil when one is already running.
    func begin() -> Int? {
        guard !isLoading else { return nil }
        isLoading = true
        token &+= 1
        return token
    }

    func progress(_ loaded: Int, _ total: Int, token t: Int) {
        guard t == token, isLoading else { return }
        // Keep showing an existing list while it is re-validated or reloaded.
        guard songs.isEmpty else { return }
        let p = Phase.loading(loaded: loaded, total: total)
        if phase != p { phase = p }
    }

    func finish(_ outcome: Outcome, token t: Int) {
        guard t == token else { return }
        isLoading = false
        switch outcome {
        case .loaded(let list, let key):
            songs = list; loadedKey = key; revision &+= 1; phase = .loaded
        case .unchanged:
            phase = songs.isEmpty ? .idle : .loaded
        case .tooLarge(let n):
            clear(); phase = .tooLarge(n)
        case .unsupported:
            clear(); phase = .unsupported
        case .failed(let message):
            // A failed refresh keeps the list it had; only an empty view says so.
            phase = songs.isEmpty ? .failed(message) : .loaded
        case .abandoned:
            phase = songs.isEmpty ? .idle : .loaded
        }
    }

    /// Forget everything — another server, or memory pressure. A load in
    /// flight is orphaned: its token no longer matches.
    func reset() {
        token &+= 1
        isLoading = false
        clear()
        phase = .idle
    }

    private func clear() {
        if !songs.isEmpty { songs = []; revision &+= 1 }
        loadedKey = nil
    }
}
