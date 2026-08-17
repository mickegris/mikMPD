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

/// Re-closes a bracket that stripping a disc marker broke open.
///
/// Real tags put the marker at the *tail of a qualifier bracket*:
/// "Clutching at Straws [24-bit Remaster CD 1]". The marker regex matches from
/// the space before "CD", which leaves the base as
/// "Clutching at Straws [24-bit Remaster" — an unbalanced tag that is then shown
/// in the UI, used as the art-cache key, and (fatally) sent to Wikipedia and
/// MusicBrainz, neither of which knows an album by that name.
///
/// Only the marker is removed, never the bracket around it: a remaster is a
/// distinct library album, and dropping the whole bracket would fold it into the
/// plain edition, which the library may hold separately. Closers are appended
/// only for openers left genuinely unmatched, so a balanced base is untouched.
nonisolated private func reclosingBrokenBracket(_ s: String) -> String {
    let closer: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    var stack: [Character] = []
    for ch in s {
        if let c = closer[ch] {
            stack.append(c)
        } else if ch == ")" || ch == "]" || ch == "}" {
            if stack.last == ch { stack.removeLast() }
        }
    }
    guard !stack.isEmpty else { return s }
    return s + String(stack.reversed())
}

/// Splits a disc marker off an album tag: "Blast from the Past [Disc 1]" →
/// ("Blast from the Past", 1); "101 [Disc B]" → ("101", 2);
/// "X [24-bit Remaster CD 1]" → ("X [24-bit Remaster]", 1). Tags without a
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
    let stripped = ns.substring(to: markerStart).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stripped.isEmpty else { return (album, nil) }
    let base = reclosingBrokenBracket(stripped)
    // Re-closing can leave nothing but an empty bracket ("X []"): that means the
    // marker *was* the whole bracket, so drop it.
    return (base.hasSuffix("()") || base.hasSuffix("[]") || base.hasSuffix("{}")
            ? String(base.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            : base,
            disc)
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

/// Grouping key for an album tag: disc markers stripped, then the punctuation that
/// taggers disagree about folded (en/em dash and minus sign → hyphen, smart quotes →
/// straight, ellipsis → "..."), trimmed and lowercased.
///
/// This is only ever a *key* — display always uses the raw tag. It exists because two
/// rips of the same album can differ by exactly one character: The Beatles' "1967-1970"
/// (ASCII hyphen, disc 2) and "1967–1970" (en dash, disc 1) are separate directories and
/// separate album tags, which split one 2-disc set into two single-disc albums with a
/// wrong disc caption on each. Folding only punctuation and case keeps this safe — the
/// artist is still part of every key that uses it, so distinct albums never merge.
nonisolated func albumGroupingKey(_ album: String) -> String {
    let base = albumBaseAndDisc(album).base
        .replacingOccurrences(of: "\u{2013}", with: "-")   // en dash
        .replacingOccurrences(of: "\u{2014}", with: "-")   // em dash
        .replacingOccurrences(of: "\u{2212}", with: "-")   // minus sign
        .replacingOccurrences(of: "\u{2018}", with: "'")   // left single quote
        .replacingOccurrences(of: "\u{2019}", with: "'")   // right single quote
        .replacingOccurrences(of: "\u{201C}", with: "\"")  // left double quote
        .replacingOccurrences(of: "\u{201D}", with: "\"")  // right double quote
        .replacingOccurrences(of: "\u{2026}", with: "...") // ellipsis
    return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// Collapse disc variants of the same album into one entry, preserving the
/// order of first appearance: ["X [Disc 1]", "X [Disc 2]", "Y"] → [("X", 2 variants), ("Y", 1)].
/// Variants that differ only by punctuation style merge too (see `albumGroupingKey`);
/// the displayed base comes from the first variant seen.
nonisolated func groupAlbumVariants(_ albums: [String]) -> [(base: String, variants: [String])] {
    var order: [String] = []
    var displayBase: [String: String] = [:]
    var groups: [String: [String]] = [:]
    for album in albums {
        let key = albumGroupingKey(album)
        if groups[key] == nil {
            order.append(key)
            displayBase[key] = albumBaseAndDisc(album).base
        }
        groups[key, default: []].append(album)
    }
    return order.map { (displayBase[$0]!, groups[$0]!) }
}

/// Disc count for display from a list of album-name variants.
/// Uses the highest disc number found in the names; falls back to variants.count
/// when none carry a disc marker. Avoids "3 discs" when disc 1 is tagged both
/// with and without a marker (e.g. "Album", "Album [Disc 1]", "Album [Disc 2]" → 2).
nonisolated func discCountFromVariants(_ variants: [String]) -> Int {
    variants.compactMap { albumBaseAndDisc($0).disc }.max() ?? variants.count
}

/// Parses an MPD `disc` tag value. "3" → 3; "1/4" → 4 (the total is authoritative
/// when present); junk → nil.
nonisolated func discTagValue(_ raw: String) -> Int? {
    let parts = raw.split(separator: "/")
    if parts.count == 2, let total = Int(parts[1].trimmingCharacters(in: .whitespaces)), total > 0 {
        return total
    }
    return Int(parts.first?.trimmingCharacters(in: .whitespaces) ?? "")
}

/// Disc count combining album-name markers and the `disc` tag, taking the higher
/// of the two so properly-tagged multi-disc albums (one name, disc tags 1–N) are
/// not reported as single-disc.
nonisolated func albumDiscCount(variants: [String], tagDiscs: Int?) -> Int {
    max(discCountFromVariants(variants), tagDiscs ?? 0)
}

/// One row in an artist-aware album list: disc variants merged per artist.
nonisolated struct AlbumGroup: Identifiable, Equatable {
    var artist: String
    var base: String
    var variants: [String]
    var tagDiscs: Int? = nil          // from listDiscCounts; nil = not yet fetched
    var id: String { "\(artist.lowercased())|\(base)" }
    /// Punctuation-folded key; use this to look up disc maps, never `base` directly.
    var groupingKey: String { albumGroupingKey(base) }
    var discCount: Int { albumDiscCount(variants: variants, tagDiscs: tagDiscs) }
}

/// Artist-aware variant of groupAlbumVariants for (artist, album) pairs from
/// `list album group albumartist`: variants merge only within one artist, so
/// same-named albums by different artists stay separate rows.
nonisolated func groupAlbumVariants(_ pairs: [(artist: String, album: String)]) -> [AlbumGroup] {
    var order: [String] = []
    var groups: [String: AlbumGroup] = [:]
    for p in pairs {
        let key = "\(p.artist.lowercased())|\(albumGroupingKey(p.album))"
        if groups[key] == nil {
            order.append(key)
            groups[key] = AlbumGroup(artist: p.artist,
                                     base: albumBaseAndDisc(p.album).base,
                                     variants: [])
        }
        groups[key]!.variants.append(p.album)
    }
    return order.map { groups[$0]! }
}

// MARK: - Library sort options

enum AlbumSort: String, CaseIterable {
    case artistAsc  = "Artist A–Z"
    case albumAsc   = "Album A–Z"
    case artistDesc = "Artist Z–A"
    case albumDesc  = "Album Z–A"
}

enum ArtistSort: String, CaseIterable {
    case az = "A–Z"
    case za = "Z–A"
}

/// Sort a grouped album list. Empty artist/base always sort last regardless of direction.
nonisolated func sortedAlbumGroups(_ groups: [AlbumGroup], by sort: AlbumSort) -> [AlbumGroup] {
    groups.sorted { a, b in
        if a.artist.isEmpty != b.artist.isEmpty { return !a.artist.isEmpty }
        if a.base.isEmpty   != b.base.isEmpty   { return !a.base.isEmpty }
        switch sort {
        case .artistAsc:
            let c = a.artist.localizedCaseInsensitiveCompare(b.artist)
            if c != .orderedSame { return c == .orderedAscending }
            return a.base.localizedCaseInsensitiveCompare(b.base) == .orderedAscending
        case .albumAsc:
            let c = a.base.localizedCaseInsensitiveCompare(b.base)
            if c != .orderedSame { return c == .orderedAscending }
            return a.artist.localizedCaseInsensitiveCompare(b.artist) == .orderedAscending
        case .artistDesc:
            let c = a.artist.localizedCaseInsensitiveCompare(b.artist)
            if c != .orderedSame { return c == .orderedDescending }
            return a.base.localizedCaseInsensitiveCompare(b.base) == .orderedDescending
        case .albumDesc:
            let c = a.base.localizedCaseInsensitiveCompare(b.base)
            if c != .orderedSame { return c == .orderedDescending }
            return a.artist.localizedCaseInsensitiveCompare(b.artist) == .orderedDescending
        }
    }
}

/// Sort an artist list. Empty strings always sort last.
nonisolated func sortedArtists(_ artists: [String], by sort: ArtistSort) -> [String] {
    artists.sorted { a, b in
        if a.isEmpty != b.isEmpty { return !a.isEmpty }
        switch sort {
        case .az: return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        case .za: return a.localizedCaseInsensitiveCompare(b) == .orderedDescending
        }
    }
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

/// Two comparison forms for an artist name, letters only and lowercased:
/// `folded` has diacritics folded to ASCII, `asciiOnly` has every non-ASCII
/// letter dropped.
///
/// Both are needed. Folding handles the ordinary disagreement between a tag and
/// an external source ("Motorhead" vs "Motörhead"). Dropping handles *mojibake*,
/// where the two sides disagree about which accented letter it is: this library
/// holds "Blue Îyster Cult", a mangling of "Blue Öyster Cult", where folding
/// gives i-vs-o and still misses, while dropping leaves "blueystercult" on both
/// sides. The previous comparison used `filter(\.isLetter)`, which keeps "ö" and
/// "î" — it stripped punctuation but preserved the very characters in dispute.
nonisolated func artistFingerprints(_ s: String) -> (folded: String, asciiOnly: String) {
    let letters = s.lowercased().filter(\.isLetter)
    // `asciiOnly` drops from the *unfolded* letters, deliberately. Folding first
    // would turn "î" into an ASCII "i" that then survives the drop, leaving
    // i-vs-o against "ö" — which is exactly the case this form exists for.
    return (letters.folding(options: .diacriticInsensitive, locale: nil),
            letters.filter(\.isASCII))
}

/// Whether two artist names plausibly name the same artist. Containment either
/// way, so "ACDC" still matches "AC/DC" and "Marillion" matches
/// "Marillion feat. Fish".
///
/// The lossy `asciiOnly` comparison is length-guarded: dropping accented letters
/// shortens a name, and two short unrelated names could otherwise collide.
nonisolated func artistCreditMatches(_ a: String, _ b: String) -> Bool {
    let x = artistFingerprints(a), y = artistFingerprints(b)
    guard !x.folded.isEmpty, !y.folded.isEmpty else { return false }
    if x.folded.contains(y.folded) || y.folded.contains(x.folded) { return true }
    guard x.asciiOnly.count >= 6, y.asciiOnly.count >= 6 else { return false }
    return x.asciiOnly.contains(y.asciiOnly) || y.asciiOnly.contains(x.asciiOnly)
}

nonisolated enum PlaybackSourceKind {
    case library
    case radio
    case cd
}

/// MPD replay gain modes, in the order the Now Playing button cycles them.
/// Keeps the valid set, the cycle order and the display names in one place —
/// the view previously duplicated the order as a string array and the names as
/// a ternary chain, so adding a mode meant editing two files in step.
nonisolated enum ReplayGainMode: String, CaseIterable {
    case off, track, album, auto

    var label: String {
        switch self {
        case .off:   "Off"
        case .track: "Track"
        case .album: "Album"
        case .auto:  "Auto"
        }
    }

    /// Next mode in the cycle, wrapping at the end.
    var next: ReplayGainMode {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

/// Parse-only; called on MPDStore's serial queue Q (MPDSong.init).
nonisolated(unsafe) let mpdDateParser = ISO8601DateFormatter()
/// Format-only; called on the main actor (loadRecentlyAdded cutoff string).
nonisolated(unsafe) let mpdDateFormatter = ISO8601DateFormatter()

/// First non-blank of two tags. A present-but-blank tag counts as **absent**: a
/// chain that stops at "" renders an empty cell, which reads as a rendering
/// fault rather than as missing data.
///
/// Returns the *original* value, deliberately untrimmed. Trimming here would
/// change `groupingArtist`, which feeds `artCacheKey`, and silently orphan the
/// cached art of every file with a padded tag.
nonisolated func tagOr(_ primary: String, _ fallback: String) -> String {
    primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : primary
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
    var lastModified: Date? = nil

    var id: String { songID.isEmpty ? "\(pos):\(file)" : songID }
    var displayTitle: String { title.isEmpty ? URL(fileURLWithPath: file).lastPathComponent : title }
    var trackNumber: Int { Int(track.components(separatedBy: "/").first ?? "") ?? 0 }
    var discNumber: Int { Int(disc.components(separatedBy: "/").first ?? "") ?? 0 }
    /// Disc for grouping/sorting: the disc tag when present, else one parsed
    /// from an album-tag suffix like "… [Disc 2]"; 0 when unknown.
    var effectiveDisc: Int { discNumber > 0 ? discNumber : (albumBaseAndDisc(album).disc ?? 0) }
    /// Album-identity artist: the albumartist tag when present (keeps
    /// compilations together), else the plain artist.
    var groupingArtist: String { tagOr(albumArtist, artist) }
    /// Artist for display and for external lookups: the track artist, else the
    /// album artist. Mirror image of `groupingArtist`, so the two agree on any
    /// file carrying only one of the tags. Files with an `AlbumArtist` and no
    /// `Artist` are common on rips where only the album-level tag was written;
    /// those used to read as "Unknown Artist" in the queue and every track list
    /// while the album page — which groups by albumartist — showed the name fine,
    /// so the name was present in the library and absent in the app. It matters
    /// beyond display too: this is what is sent to Wikipedia, MusicBrainz and
    /// LRCLIB, so the fallback turns a guaranteed-miss lookup into one that can
    /// match.
    var displayArtist: String { tagOr(artist, albumArtist) }
    /// Keyed on `groupingArtist`, not the raw `artist` tag: album rows come from
    /// `list album group albumartist`, so a compilation track keyed by its own
    /// artist landed in a different cache entry than its own album's tile.
    var artKey: String { artCacheKey(artist: groupingArtist, album: album) }
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
        if let lm = r["last-modified"] { lastModified = mpdDateParser.date(from: lm) }
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
    var snapcastHost: String = ""   // empty = use MPD host
    var snapcastPort: Int = 1705
}

// Custom decoder for back-compat: legacy profiles lack snapcastHost/Port.
// encode(to:) remains synthesized — it includes all properties.
extension MPDServerProfile {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decodeIfPresent(UUID.self,   forKey: .id)            ?? UUID()
        name          = try c.decode(          String.self, forKey: .name)
        host          = try c.decode(          String.self, forKey: .host)
        port          = try c.decodeIfPresent(Int.self,     forKey: .port)          ?? 6600
        streamURL     = try c.decodeIfPresent(String.self,  forKey: .streamURL)     ?? ""
        lastPartition = try c.decodeIfPresent(String.self,  forKey: .lastPartition) ?? ""
        snapcastHost  = try c.decodeIfPresent(String.self,  forKey: .snapcastHost)  ?? ""
        snapcastPort  = try c.decodeIfPresent(Int.self,     forKey: .snapcastPort)  ?? 1705
    }
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
        // `groupingArtist`: history rows show album tiles keyed by `artCacheKey`,
        // so the artist stored here has to be the one that key is built from.
        return RecentlyPlayedEntry(file: song.file, title: song.displayTitle,
                                   artist: song.groupingArtist, album: song.album, playedAt: now)
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

/// Whether a remembered "Playing from <playlist>" label still describes the queue.
///
/// Compares as **sets**, not sequences: after `shuffle` the queue's order
/// deliberately differs from the playlist's, and that is the case this label
/// most needs to survive. The queue must be a *subset* — a superset means tracks
/// were added afterwards, so the queue is no longer just that playlist and the
/// label would be a lie.
nonisolated func playbackContextStillValid(queueFiles: Set<String>,
                                           playlistFiles: Set<String>) -> Bool {
    guard !queueFiles.isEmpty, !playlistFiles.isEmpty else { return false }
    return queueFiles.isSubset(of: playlistFiles)
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

nonisolated struct MPDStats {
    var artists: Int = 0
    var albums: Int = 0
    var songs: Int = 0
    var uptime: Int = 0
    var dbPlaytime: Int = 0
    var dbUpdate: Date? = nil
    var playtime: Int = 0
}

/// Formats a duration in seconds as "Nd Nh Nm", omitting zero components except minutes.
nonisolated func formatDuration(_ seconds: Int) -> String {
    guard seconds > 0 else { return "0 min" }
    let days  = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let mins  = (seconds % 3600) / 60
    var parts: [String] = []
    if days  > 0 { parts.append("\(days)d") }
    if hours > 0 { parts.append("\(hours)h") }
    if mins  > 0 || parts.isEmpty { parts.append("\(mins)m") }
    return parts.joined(separator: " ")
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
