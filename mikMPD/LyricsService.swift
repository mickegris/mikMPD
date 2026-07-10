// LyricsService.swift
//
// Fetches plain and time-synced lyrics from LRCLIB (https://lrclib.net) —
// a free, open-source, community-maintained lyrics database whose contents are
// released into the public domain. No API key required.
//
// Modeled on WikipediaService: a Swift `actor` with an in-memory cache backed by
// a disk cache (Caches/lyrics/). Negative results ("no lyrics exist") are cached
// too so we don't hammer the API for tracks that simply have no lyrics.
import Foundation

/// A single timed line from a synced LRC source.
/// `nonisolated` — pure value types used from both the actor and the main actor
/// (the project's default isolation is MainActor).
nonisolated struct LyricLine: Equatable, Codable {
    let secs: Double
    let text: String
}

/// Lyrics for one track. `plain` and `synced` are not mutually exclusive —
/// LRCLIB often provides both. Synced enables the highlighted, auto-scrolling view.
nonisolated struct Lyrics: Equatable, Codable {
    var plain: String?
    var synced: [LyricLine]?
    var instrumental: Bool

    /// True when there's nothing meaningful to show.
    var isEmpty: Bool { plain == nil && synced == nil && !instrumental }
}

/// Load state for the current track's lyrics, consumed by the view.
enum LyricsState: Equatable {
    case loading
    case unavailable
    case loaded(Lyrics)
}

actor LyricsService {
    static let shared = LyricsService()

    /// Seconds to nudge synced-lyric highlighting earlier. LRCLIB timestamps tend
    /// to mark when a line *finishes* appearing; a small offset keeps the
    /// highlight from running ahead of the vocals.
    static let syncOffset: Double = 0.5

    private static let base = "https://lrclib.net/api"
    private static let userAgent = "mikMPD (https://github.com/mickegris/mikMPD)"

    // In-memory cache. A cached `nil` means "known: this track has no lyrics".
    private var cache: [String: Lyrics?] = [:]

    // MARK: - Disk cache

    private struct CachedBox: Codable { let lyrics: Lyrics? }

    private static let diskCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func diskPath(key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return diskCacheDir.appendingPathComponent(safe + ".json")
    }

    private static func loadFromDisk(key: String) -> Lyrics?? {
        guard let data = try? Data(contentsOf: diskPath(key: key)),
              let box = try? JSONDecoder().decode(CachedBox.self, from: data)
        else { return nil }
        return .some(box.lyrics)
    }

    private static func saveToDisk(key: String, value: Lyrics?) {
        guard let data = try? JSONEncoder().encode(CachedBox(lyrics: value)) else { return }
        try? data.write(to: diskPath(key: key), options: .atomic)
    }

    // MARK: - Fetch

    /// Fetch lyrics for a track. Tries an exact match first (duration narrows to
    /// the right recording), then falls back to a relaxed search. Returns `nil`
    /// when no lyrics exist for the track.
    func fetch(artist: String, title: String, album: String, duration: Double) async -> Lyrics? {
        let key = "\(artist)|\(title)|\(album)".lowercased()

        if let cached = cache[key] { return cached }
        if let disk = Self.loadFromDisk(key: key) {
            cache[key] = disk
            return disk
        }
        guard !title.isEmpty else { return nil }

        var result: Lyrics? = nil
        var responded = false   // did the server give us an HTTP answer at all?

        // --- Exact match (preferred) ---------------------------------------
        var exact = URLComponents(string: "\(Self.base)/get")!
        exact.queryItems = [
            .init(name: "artist_name", value: artist),
            .init(name: "track_name",  value: title),
            .init(name: "album_name",  value: album),
        ]
        if duration > 0 {
            exact.queryItems?.append(.init(name: "duration", value: String(Int(duration))))
        }
        let exactHit = await requestOne(exact.url)
        responded = responded || exactHit.responded
        if let lyrics = exactHit.lyrics {
            result = lyrics
        } else {
            // --- Fallback: search (ignores album / duration) ---------------
            var search = URLComponents(string: "\(Self.base)/search")!
            search.queryItems = [
                .init(name: "artist_name", value: artist),
                .init(name: "track_name",  value: title),
            ]
            let searchHit = await requestFirst(search.url)
            responded = responded || searchHit.responded
            result = searchHit.lyrics
        }

        // Only cache when the server actually answered — a transport failure
        // (offline, timeout) must stay retryable, not become a permanent
        // "no lyrics exist" verdict on disk.
        if result != nil || responded {
            cache[key] = .some(result)
            Self.saveToDisk(key: key, value: result)
        }
        return result
    }

    /// Request the `/get` endpoint (a single JSON object).
    private func requestOne(_ url: URL?) async -> (lyrics: Lyrics?, responded: Bool) {
        let (data, responded) = await get(url)
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, responded) }
        let lyrics = Self.parse(obj)
        return (lyrics.isEmpty ? nil : lyrics, responded)
    }

    /// Request the `/search` endpoint (a JSON array) and take the first hit.
    private func requestFirst(_ url: URL?) async -> (lyrics: Lyrics?, responded: Bool) {
        let (data, responded) = await get(url)
        guard let data,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first
        else { return (nil, responded) }
        let lyrics = Self.parse(first)
        return (lyrics.isEmpty ? nil : lyrics, responded)
    }

    /// GET a URL. `responded` is true whenever an HTTP response arrived
    /// (including 404 "no lyrics"), false on transport-level failure.
    private func get(_ url: URL?) async -> (data: Data?, responded: Bool) {
        guard let url else { return (nil, false) }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return (nil, false)
        }
        let ok = (resp as? HTTPURLResponse)?.statusCode == 200
        return (ok ? data : nil, true)
    }

    // MARK: - Parsing

    private static func parse(_ obj: [String: Any]) -> Lyrics {
        let plain = (obj["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let syncedRaw = (obj["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let synced = syncedRaw.flatMap(parseLRC)
        let instrumental = (obj["instrumental"] as? Bool) ?? false
        return Lyrics(plain: plain, synced: synced, instrumental: instrumental)
    }

    /// Parse an LRC string into sorted, timed lyric lines. Returns `nil` when no
    /// valid timestamped lines are found. LRC line format: `[mm:ss.xx] text`.
    static func parseLRC(_ lrc: String) -> [LyricLine]? {
        var lines: [LyricLine] = []
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["),
                  let close = trimmed.firstIndex(of: "]") else { continue }
            let stamp = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let text = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let secs = parseTimestamp(stamp) {
                lines.append(LyricLine(secs: secs, text: text))
            }
        }
        guard !lines.isEmpty else { return nil }
        lines.sort { $0.secs < $1.secs }
        return lines
    }

    /// Parse `mm:ss.xx` (or `mm:ss`) into total seconds.
    private static func parseTimestamp(_ ts: String) -> Double? {
        let parts = ts.split(separator: ":")
        guard parts.count == 2,
              let mins = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let secs = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return mins * 60 + secs
    }
}
