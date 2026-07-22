// Models.swift
import Foundation
import UIKit

nonisolated func artCacheKey(artist: String, album: String) -> String {
    let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    // Disc variants ("X [Disc 1]", "X (CD 2)") share one cover
    let trimmedAlbum = albumBaseAndDisc(album).base.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedArtist.isEmpty || !trimmedAlbum.isEmpty else { return "" }
    return "\(trimmedArtist)|\(trimmedAlbum)".lowercased()
}

/// Trailing disc markers on album tags. A delimiter (whitespace, dash/colon/comma,
/// or an opening bracket) must precede the keyword so titles like "ABCD2" survive.
/// Disc letters ("101 [Disc A]") are accepted only in bracketed form — a bare
/// "… CD A" is too ambiguous. Spelled-out numbers ("Disc One") and bracketed
/// subtitles ("[Disc 1: Live]") are deliberately not matched — those pass through.
nonisolated private enum DiscMarker {
    static let numbered = try! NSRegularExpression(
        pattern: #"(?:[\s\-–—:,]+|\s*[(\[{])\s*(?:disc|disk|cd)[\s.\-]*([0-9]{1,3})\s*[)\]}]?\s*$"#,
        options: [.caseInsensitive])
    static let lettered = try! NSRegularExpression(
        pattern: #"\s*[(\[{]\s*(?:disc|disk|cd)[\s.\-]*([a-z])\s*[)\]}]\s*$"#,
        options: [.caseInsensitive])
}

/// Splits a disc marker off an album tag: "Blast from the Past [Disc 1]" →
/// ("Blast from the Past", 1); "101 [Disc B]" → ("101", 2). Tags without a
/// marker — or that are nothing but a marker — come back unchanged with a nil disc.
nonisolated func albumBaseAndDisc(_ album: String) -> (base: String, disc: Int?) {
    let ns = album as NSString
    let range = NSRange(location: 0, length: ns.length)
    let disc: Int
    let markerStart: Int
    if let m = DiscMarker.numbered.firstMatch(in: album, range: range),
       let discRange = Range(m.range(at: 1), in: album),
       let d = Int(album[discRange]) {
        disc = d; markerStart = m.range.location
    } else if let m = DiscMarker.lettered.firstMatch(in: album, range: range),
              let discRange = Range(m.range(at: 1), in: album),
              let scalar = album[discRange].lowercased().unicodeScalars.first {
        disc = Int(scalar.value) - Int(UnicodeScalar("a").value) + 1  // A→1, B→2, …
        markerStart = m.range.location
    } else {
        return (album, nil)
    }
    let base = ns.substring(to: markerStart).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !base.isEmpty else { return (album, nil) }
    return (base, disc)
}

/// Extra cleaning for *external lookups only* (Wikipedia/MusicBrainz), never for
/// grouping or art keys — a remaster is a distinct library album but the same
/// Wikipedia article. After disc markers, iteratively strips trailing bracketed
/// edition qualifiers: "[24-bit remaster]", "(2005 Remaster)", "[Deluxe Edition]",
/// "(Live)". Brackets without a qualifier keyword or year are kept
/// ("(What's the Story) Morning Glory?" is untouched — its bracket isn't trailing).
nonisolated private enum EditionQualifier {
    static let trailingBracket = try! NSRegularExpression(
        pattern: #"[(\[{]([^)\]}]*)[)\]}]\s*$"#, options: [])
    // Keyword words, years, N-bit/kHz, bare catalog digit runs ("88697…"),
    // and letter–digit catalog numbers ("VICP-60852"). "Part 2" has none of
    // these (space between word and digit) and must stay untouched.
    static let keywords = try! NSRegularExpression(
        pattern: #"(?i)\b(remaster(ed)?|deluxe|edition|expanded|anniversary|bonus|reissue|mono|stereo|live|explicit|hi-?res|sacd|original|recording|version|japan|import|promo|limited)\b|\b(19|20)[0-9]{2}\b|\b[0-9]+\s*-?\s*(bit|khz)\b|\b[0-9]{4,}\b|\b[a-z]{2,6}-?[0-9]{3,}\b"#,
        options: [])
}

nonisolated func albumLookupTitle(_ album: String) -> String {
    var s = albumBaseAndDisc(album).base
    while true {
        let ns = s as NSString
        guard let m = EditionQualifier.trailingBracket.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.range.location > 0
        else { break }
        let content = ns.substring(with: m.range(at: 1))
        let contentRange = NSRange(location: 0, length: (content as NSString).length)
        guard EditionQualifier.keywords.firstMatch(in: content, range: contentRange) != nil else { break }
        let stripped = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { break }
        s = albumBaseAndDisc(stripped).base
    }
    return s
}

/// Collapse disc variants of the same album into one entry, preserving the
/// order of first appearance: ["X [Disc 1]", "X [Disc 2]", "Y"] → [("X", 2 variants), ("Y", 1)].
nonisolated func groupAlbumVariants(_ albums: [String]) -> [(base: String, variants: [String])] {
    var order: [String] = []
    var groups: [String: [String]] = [:]
    for album in albums {
        let base = albumBaseAndDisc(album).base
        if groups[base] == nil { order.append(base) }
        groups[base, default: []].append(album)
    }
    return order.map { ($0, groups[$0]!) }
}

/// One row in an artist-aware album list: disc variants merged per artist.
nonisolated struct AlbumGroup: Identifiable, Equatable {
    var artist: String
    var base: String
    var variants: [String]
    var id: String { "\(artist.lowercased())|\(base)" }
}

/// Artist-aware variant of groupAlbumVariants for (artist, album) pairs from
/// `list album group albumartist`: variants merge only within one artist, so
/// same-named albums by different artists stay separate rows.
nonisolated func groupAlbumVariants(_ pairs: [(artist: String, album: String)]) -> [AlbumGroup] {
    var order: [String] = []
    var groups: [String: AlbumGroup] = [:]
    for p in pairs {
        let base = albumBaseAndDisc(p.album).base
        let key = "\(p.artist.lowercased())|\(base)"
        if groups[key] == nil {
            order.append(key)
            groups[key] = AlbumGroup(artist: p.artist, base: base, variants: [])
        }
        groups[key]!.variants.append(p.album)
    }
    return order.map { groups[$0]! }
}

/// Album track order: disc first (tag or album-suffix derived), then track number.
nonisolated func sortedByDiscAndTrack(_ songs: [MPDSong]) -> [MPDSong] {
    songs.sorted { ($0.effectiveDisc, $0.trackNumber) < ($1.effectiveDisc, $1.trackNumber) }
}

/// Collapse duplicate library copies of the same track (first occurrence wins).
/// The artist is part of the key, so same-titled tracks on same-named albums by
/// *different* artists never collapse — that mistake forced an earlier revert.
/// Display-only: the album page uses it; queue/search show the real files.
nonisolated func dedupedAlbumTracks(_ songs: [MPDSong]) -> [MPDSong] {
    var seen = Set<String>()
    return songs.filter { s in
        seen.insert("\(s.groupingArtist.lowercased())|\(s.effectiveDisc)|\(s.trackNumber)|\(s.displayTitle.lowercased())").inserted
    }
}

/// Word-level title comparison for external lookups (Wikipedia article titles,
/// MusicBrainz release titles): at least two-thirds of the query's significant
/// words (3+ chars, stopwords dropped) — and no fewer than two — must appear as
/// whole words in the candidate. Substring matching is deliberately avoided:
/// "the" must not hit "theatre", and "Best of the Doors" must not match the
/// debut album "The Doors". Callers pass normalized/lowercased strings or rely
/// on the internal lowercasing.
nonisolated func titleTokensMatch(candidate: String, query: String) -> Bool {
    let stopwords: Set<String> = ["the", "and"]
    func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
    let queryTokens = words(query).filter { $0.count >= 3 && !stopwords.contains($0) }
    guard queryTokens.count >= 2 else { return false }
    let hits = queryTokens.intersection(words(candidate)).count
    return hits * 3 >= queryTokens.count * 2 && hits >= 2
}

nonisolated enum PlaybackSourceKind {
    case library
    case radio
    case cd
}

nonisolated struct MPDSong: Identifiable, Equatable {
    var file:     String = ""
    var title:    String = ""
    var artist:   String = ""
    var album:    String = ""
    var albumArtist: String = ""
    var track:    String = ""
    var disc:     String = ""
    var duration: Double = 0
    var pos:      Int    = 0
    var songID:   String = ""

    var id: String { songID.isEmpty ? "\(pos):\(file)" : songID }
    var displayTitle: String { title.isEmpty ? URL(fileURLWithPath: file).lastPathComponent : title }
    var trackNumber: Int { Int(track.components(separatedBy: "/").first ?? "") ?? 0 }
    var discNumber: Int { Int(disc.components(separatedBy: "/").first ?? "") ?? 0 }
    /// Disc for grouping/sorting: the disc tag when present, else one parsed
    /// from an album-tag suffix like "… [Disc 2]"; 0 when unknown.
    var effectiveDisc: Int { discNumber > 0 ? discNumber : (albumBaseAndDisc(album).disc ?? 0) }
    /// Album-identity artist: the albumartist tag when present (keeps
    /// compilations together), else the plain artist.
    var groupingArtist: String { albumArtist.isEmpty ? artist : albumArtist }
    var artKey: String { artCacheKey(artist: artist, album: album) }
    var sourceKind: PlaybackSourceKind {
        let trimmedFile = file.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedFile = trimmedFile.lowercased()
        if lowercasedFile.hasPrefix("cdda:") {
            return .cd
        }
        if let scheme = URL(string: trimmedFile)?.scheme?.lowercased(),
           ["http", "https", "icy"].contains(scheme) {
            return .radio
        }
        return .library
    }
    var fallbackArtAssetName: String {
        switch sourceKind {
        case .library: "MikMPDLogo"
        case .radio: "RadioFallbackArt"
        case .cd: "CDFallbackArt"
        }
    }

    init() {}
    init(_ r: MPDRecord) {
        file     = r["file"]     ?? ""
        title    = r["title"]    ?? ""
        artist   = r["artist"]   ?? ""
        album    = r["album"]    ?? ""
        albumArtist = r["albumartist"] ?? ""
        track    = r["track"]    ?? ""
        disc     = r["disc"]     ?? ""
        duration = Double(r["duration"] ?? "0") ?? 0
        pos      = Int(r["pos"]  ?? "0") ?? 0
        songID   = r["id"]       ?? ""
    }
}

nonisolated struct MPDOutput: Identifiable, Equatable {
    var outputID: String
    var name:     String
    var enabled:  Bool
    var plugin:   String
    var id: String { outputID }
    init(_ r: MPDRecord) {
        outputID = r["outputid"]      ?? UUID().uuidString  // fallback keeps IDs unique
        name     = r["outputname"]    ?? "Output"
        enabled  = r["outputenabled"] == "1"
        plugin   = r["plugin"]        ?? ""
    }
}

nonisolated struct MPDPlaylist: Identifiable, Equatable {
    var name: String
    var lastModified: String = ""
    var id: String { name }
}

/// A saved MPD server. The password is not part of the profile — it lives in
/// the Keychain under "mpd_password_<id>" since this struct is stored as JSON
/// in UserDefaults.
nonisolated struct MPDServerProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 6600
    var streamURL: String = ""      // per-server httpd output URL
    var lastPartition: String = ""  // per-server "remember partitions" value
}

/// Build the initial profile from pre-multi-server settings (one-time migration).
nonisolated func migratedLegacyProfile(host: String, portStr: String, streamURL: String, lastPartition: String?) -> MPDServerProfile {
    MPDServerProfile(name: host, host: host, port: Int(portStr) ?? 6600,
                     streamURL: streamURL, lastPartition: lastPartition ?? "")
}

/// A legacy (pre-multi-server) host was only ever *persisted* if the user
/// actually configured one — @AppStorage defaults are never written to
/// UserDefaults. On a fresh install there is nothing to migrate; fabricating a
/// profile from the old hardcoded placeholder produced a bogus "192.168.1.1"
/// server that the app then tried to dial.
nonisolated func shouldMigrateLegacyServer(persistedHost: String?, hasServers: Bool) -> Bool {
    guard !hasServers,
          let host = persistedHost?.trimmingCharacters(in: .whitespaces),
          !host.isEmpty else { return false }
    return true
}

/// MPD playlist names are file names (NAME.m3u): returns the trimmed name,
/// or nil for empty names or names containing path separators/newlines.
nonisolated func validatePlaylistName(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.contains("/"), !trimmed.contains("\\"),
          !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
    return trimmed
}

/// Songs from `listplaylistinfo` carry no pos/id fields; assign pos from the
/// record index so duplicate files in a playlist still get unique ids.
nonisolated func songsAssigningPositions(_ records: [MPDRecord]) -> [MPDSong] {
    records.enumerated().map { i, r in
        var s = MPDSong(r)
        s.pos = i
        return s
    }
}

// MARK: - Recently played

nonisolated struct RecentlyPlayedEntry: Codable, Identifiable, Equatable {
    var file: String
    var title: String
    var artist: String
    var album: String
    var playedAt: Date
    var id: String { "\(file)|\(playedAt.timeIntervalSince1970)" }
}

/// Commits a song to history once it has played ~30 s continuously (half its
/// duration for short tracks, Spotify-style), driven by the store's poll.
/// Accumulates wall-clock deltas between ticks (poll cadence is 1 s foreground /
/// 2 s while streaming; a single delta is capped so suspended-app gaps don't
/// count). A file change resets — skipped songs never commit. One commit per
/// continuous play of a file; repeat-one therefore logs once, not per loop.
nonisolated struct RecentlyPlayedRecorder {
    private var file = ""
    private var accumulated: TimeInterval = 0
    private var lastTick: Date?
    private var committed = false

    mutating func tick(song: MPDSong, isPlaying: Bool, now: Date) -> RecentlyPlayedEntry? {
        if song.file != file {
            file = song.file
            accumulated = 0
            committed = false
            lastTick = (isPlaying && !file.isEmpty) ? now : nil
            return nil
        }
        guard !file.isEmpty else { lastTick = nil; return nil }
        guard isPlaying else { lastTick = nil; return nil }  // pause keeps progress, stops the clock
        if let last = lastTick {
            accumulated += min(now.timeIntervalSince(last), 5)
        }
        lastTick = now
        guard !committed else { return nil }
        let threshold = song.duration > 0 ? min(30, max(5, song.duration / 2)) : 30
        guard accumulated >= threshold else { return nil }
        committed = true
        return RecentlyPlayedEntry(file: song.file, title: song.displayTitle,
                                   artist: song.artist, album: song.album, playedAt: now)
    }
}

/// Retention: drop entries older than `maxAge`, then trim to the `cap` newest.
/// Expects (and preserves) newest-first order.
nonisolated func prunedRecentHistory(_ entries: [RecentlyPlayedEntry], now: Date,
                                     maxAge: TimeInterval = 30 * 86_400,
                                     cap: Int = 100) -> [RecentlyPlayedEntry] {
    Array(entries.filter { now.timeIntervalSince($0.playedAt) <= maxAge }.prefix(cap))
}

nonisolated struct RecentAlbum: Identifiable, Equatable {
    var artist: String
    var album: String        // raw tag from the newest entry; empty for album-less tiles
    var file: String         // representative file (album-less replay target)
    var title: String        // display title for album-less tiles (radio/loose files)
    var lastPlayed: Date
    var albumless: Bool      // true when keyed on file, not album
    var id: String { albumless ? file : artCacheKey(artist: artist, album: album) }
}

/// Derives album groups from track history (expects newest-first input), returning newest-first.
/// Disc variants with the same artCacheKey collapse into one tile. Entries without an album
/// tag group by file so radio/loose files still appear as tiles.
nonisolated func recentAlbumGroups(_ entries: [RecentlyPlayedEntry]) -> [RecentAlbum] {
    var seen: Set<String> = []
    var result: [RecentAlbum] = []
    for entry in entries {
        let albumless = entry.album.isEmpty
        let key = albumless ? entry.file : artCacheKey(artist: entry.artist, album: entry.album)
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        result.append(RecentAlbum(
            artist: entry.artist,
            album: entry.album,
            file: entry.file,
            title: entry.title,
            lastPlayed: entry.playedAt,
            albumless: albumless
        ))
    }
    return result
}

nonisolated struct MPDBrowseItem: Identifiable {
    enum Kind { case directory, file, playlist }
    var kind: Kind
    var path: String
    var id: String { kind == .directory ? "d:\(path)" : kind == .file ? "f:\(path)" : "p:\(path)" }
    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
    var sfSymbol: String {
        switch kind {
        case .directory: "folder.fill"
        case .file:      "music.note"
        case .playlist:  "list.bullet.rectangle"
        }
    }
}

/// Convert SwiftUI's onMove destination (an index into the pre-removal array)
/// to the TO argument of MPD's `move`/`playlistmove` (an index after removal).
nonisolated func mpdMoveTarget(from: Int, to destination: Int) -> Int {
    destination > from ? destination - 1 : destination
}

func formatTime(_ s: Double) -> String {
    guard s > 0, s.isFinite else { return "0:00" }
    let t = Int(s)
    return "\(t / 60):\(String(format: "%02d", t % 60))"
}

nonisolated func relativeDay(_ date: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day],
        from: cal.startOfDay(for: date),
        to: cal.startOfDay(for: now)).day ?? 0
    switch days {
    case 0: return "Today"
    case 1: return "Yesterday"
    default: return "\(days) days ago"
    }
}
