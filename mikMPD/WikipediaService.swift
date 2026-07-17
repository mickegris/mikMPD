import Foundation
import UIKit
actor WikipediaService {
    static let shared = WikipediaService()
    private var cache: [String: String] = [:]
    private var imageCache: [String: UIImage] = [:]
    private static let imageDiskCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("artistart")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static func imageDiskPath(key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return imageDiskCacheDir.appendingPathComponent(safe + ".jpg")
    }
    private static func loadImageFromDisk(key: String) -> UIImage? {
        guard let data = try? Data(contentsOf: imageDiskPath(key: key)) else { return nil }
        return UIImage(data: data)
    }
    private static func saveImageToDisk(key: String, image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: imageDiskPath(key: key), options: .atomic)
    }
    private static let musicKeywords = ["band", "musician", "singer", "rapper", "songwriter",
        "musical", "album", "discography", "genre", "record label", "vocalist", "guitarist",
        "drummer", "bassist", "hip hop", "rock", "pop", "jazz", "metal", "punk", "solo artist",
        "group", "duo", "trio", "quartet", "ensemble", "orchestra"]

    private func isMusicRelated(_ text: String) -> Bool {
        let lower = text.lowercased()
        return Self.musicKeywords.contains { lower.contains($0) }
    }

    /// Fetch album info — searches Wikipedia and validates the result is about this album.
    func fetchAlbum(album rawAlbum: String, artist: String) async -> String? {
        // Wikipedia only knows the base title — strip disc markers ("[Disc 2]")
        // and edition qualifiers ("[24-bit remaster]"); stripping before the
        // cache key also shares one entry across the variants. Then normalize
        // Unicode characters (e.g. … → ...) for Wikipedia lookups.
        let album = albumLookupTitle(rawAlbum).normalizedForLookup
        let key = "album:\(album)|\(artist)"
        if let c = cache[key] { return c.isEmpty ? nil : c }
        let artist = artist.normalizedForLookup
        // Try direct title with common Wikipedia album naming patterns
        let queries = artist.isEmpty ? ["\(album) (album)"] :
            ["\(album) (\(artist) album)", "\(album) (album)"]
        for q in queries {
            if let r = await summaryData(title: q), !r.extract.isEmpty {
                cache[key] = r.extract; return r.extract
            }
        }
        // Plain exact title — distinctive album names ("An Acoustic Evening at
        // the Vienna Opera House") are articles without any "(album)" suffix.
        // Validated hard: must read as music and pass the artist check, so an
        // album named after a city/person doesn't pick up the wrong article.
        if let r = await summaryData(title: album), !r.extract.isEmpty, isMusicRelated(r.extract),
           Self.albumResultMatches(title: album, extract: r.extract, album: album, artist: artist) {
            cache[key] = r.extract; return r.extract
        }
        // Search with progressively looser queries. A hit whose *title* names the
        // album wins immediately; extract-only matches are kept as fallback —
        // a sequel's article often cites the album by full name in its extract
        // ("Live at Carnegie Hall…" mentions the Vienna Opera House album).
        let searches = artist.isEmpty
            ? ["\(album) album"]
            : ["\(album) \(artist) album", "\(album) album"]
        var extractOnlyMatch: String? = nil
        for searchQ in searches {
            for ttl in await searchTitles(searchQ) {
                guard let r = await summaryData(title: ttl), !r.extract.isEmpty,
                      Self.albumResultMatches(title: ttl, extract: r.extract, album: album, artist: artist)
                else { continue }
                if Self.titleMatchesAlbum(title: ttl, album: album) {
                    cache[key] = r.extract; return r.extract
                }
                if extractOnlyMatch == nil { extractOnlyMatch = r.extract }
            }
        }
        if let e = extractOnlyMatch { cache[key] = e; return e }
        cache[key] = ""; return nil
    }

    /// Strong signal: the article *title* names the album (exact containment
    /// after normalization, or most of the album's words appear in the title).
    nonisolated static func titleMatchesAlbum(title: String, album: String) -> Bool {
        let t = title.normalizedForLookup.lowercased()
        let a = album.normalizedForLookup.lowercased()
        return t.contains(a) || tokensMostlyPresent(a, in: t)
    }

    /// A search hit must relate to this album, not just the artist's
    /// discography. Both sides are dash/quote-normalized: Wikipedia titles
    /// use en dashes ("1967–1970") where tags usually have hyphens.
    nonisolated static func albumResultMatches(title: String, extract: String, album: String, artist: String) -> Bool {
        let albumLower = album.normalizedForLookup.lowercased()
        let titleLower = title.normalizedForLookup.lowercased()
        let extractLower = extract.normalizedForLookup.lowercased()
        let aboutAlbum = titleLower.contains(albumLower) || extractLower.contains(albumLower)
            || Self.tokensMostlyPresent(albumLower, in: titleLower + " " + extractLower)
        let artistLower = artist.normalizedForLookup.lowercased()
        let aboutArtist = artist.isEmpty
            || extractLower.contains(artistLower)
            || extractLower.filter(\.isLetter).contains(artistLower.filter(\.isLetter))
        return aboutAlbum && aboutArtist
    }

    /// Fallback for decorated tags ("Beacon Theatre. Live from...") whose exact
    /// string never appears in the article: at least two-thirds of the album's
    /// words (3+ chars) must appear in the result. The artist check still guards
    /// against unrelated hits.
    nonisolated private static func tokensMostlyPresent(_ needle: String, in haystack: String) -> Bool {
        let tokens = needle.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        guard !tokens.isEmpty else { return false }
        let hits = tokens.filter { haystack.contains($0) }.count
        return hits * 3 >= tokens.count * 2
    }

    /// Fetch artist info with music disambiguation.
    func fetchArtist(query: String) async -> String? {
        let key = "artist:\(query)"
        if let c = cache[key] { return c.isEmpty ? nil : c }
        let query = query.normalizedForLookup
        // Try disambiguation suffixes first (most precise)
        for suffix in ["(band)", "(musician)", "(singer)", "(rapper)"] {
            if let r = await summaryData(title: "\(query) \(suffix)"), !r.extract.isEmpty { cache[key]=r.extract; return r.extract }
        }
        // Try exact name, but only accept if content is music-related
        if let r = await summaryData(title: query), !r.extract.isEmpty, isMusicRelated(r.extract) {
            cache[key] = r.extract; return r.extract
        }
        cache[key]=""; return nil
    }

    /// Fetch artist image from Wikipedia using music disambiguation.
    func fetchArtistImage(query: String) async -> UIImage? {
        let key = "artistimg:\(query)"
        if let c = imageCache[key] { return c }
        if let disk = Self.loadImageFromDisk(key: key) { imageCache[key]=disk; return disk }
        let query = query.normalizedForLookup
        for suffix in ["(band)", "(musician)", "(singer)", "(rapper)"] {
            if let img = await downloadSummaryImage(title: "\(query) \(suffix)") { imageCache[key]=img; Self.saveImageToDisk(key:key,image:img); return img }
        }
        // Try exact name, only accept if the summary is music-related
        if let r = await summaryData(title: query), isMusicRelated(r.extract),
           let img = await downloadSummaryImage(title: query) { imageCache[key]=img; Self.saveImageToDisk(key:key,image:img); return img }
        return nil
    }
    private struct SummaryResult { let extract: String; let imageURL: String? }
    /// Characters safe in a Wikipedia title path segment (urlPathAllowed minus "/" which would break the path).
    private static let wikiPathAllowed: CharacterSet = {
        var cs = CharacterSet.urlPathAllowed
        cs.remove("/")  // breaks path segments (e.g. AC/DC)
        cs.remove("+")  // some servers decode as space
        return cs
    }()
    private func summaryData(title: String) async -> SummaryResult? {
        let enc = title.replacingOccurrences(of:" ",with:"_").addingPercentEncoding(withAllowedCharacters: Self.wikiPathAllowed) ?? title
        guard let url=URL(string:"https://en.wikipedia.org/api/rest_v1/page/summary/\(enc)"),
              let (d,r)=try? await URLSession.shared.data(from:url),(r as? HTTPURLResponse)?.statusCode==200,
              let j=try? JSONSerialization.jsonObject(with:d) as? [String:Any],
              let t=j["extract"] as? String,!t.isEmpty,(j["type"] as? String) != "disambiguation"
        else { return nil }
        let imgURL = (j["thumbnail"] as? [String:Any])?["source"] as? String
        return SummaryResult(extract: t, imageURL: imgURL)
    }
    private func downloadSummaryImage(title: String) async -> UIImage? {
        guard let r = await summaryData(title: title), let src = r.imageURL,
              let url = URL(string: src),
              let (data, _) = try? await URLSession.shared.data(from: url)
        else { return nil }
        return UIImage(data: data)
    }
    /// Top search hits (a few, not one — the best match for decorated album tags
    /// is often ranked below a discography or artist page that validation rejects).
    private func searchTitles(_ q: String) async -> [String] {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [.init(name:"action",value:"query"),.init(name:"list",value:"search"),
                        .init(name:"srsearch",value:q),.init(name:"format",value:"json"),.init(name:"srlimit",value:"3")]
        guard let url = c.url, let (d, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let qr = j["query"] as? [String: Any], let sr = qr["search"] as? [[String: Any]]
        else { return [] }
        return sr.compactMap { $0["title"] as? String }
    }
}
