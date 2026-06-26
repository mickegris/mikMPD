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

    /// Fetch album info — searches Wikipedia and validates the result mentions the artist.
    func fetchAlbum(album: String, artist: String) async -> String? {
        let key = "album:\(album)|\(artist)"
        if let c = cache[key] { return c.isEmpty ? nil : c }
        // Try direct title with common Wikipedia album naming patterns
        let queries = artist.isEmpty ? ["\(album) (album)"] :
            ["\(album) (\(artist) album)", "\(album) (album)"]
        for q in queries {
            if let r = await summaryData(title: q), !r.extract.isEmpty {
                cache[key] = r.extract; return r.extract
            }
        }
        // Search with artist context and validate result mentions artist or album terms
        let searchQ = artist.isEmpty ? "\(album) album" : "\(album) \(artist) album"
        if let ttl = await searchTitle(searchQ),
           let r = await summaryData(title: ttl), !r.extract.isEmpty {
            let lower = r.extract.lowercased()
            let relevant = artist.isEmpty || lower.contains(artist.lowercased())
                || lower.contains("album") || lower.contains("studio album")
            if relevant { cache[key] = r.extract; return r.extract }
        }
        cache[key] = ""; return nil
    }

    /// Fetch artist info with music disambiguation.
    func fetchArtist(query: String) async -> String? {
        let key = "artist:\(query)"
        if let c = cache[key] { return c.isEmpty ? nil : c }
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
        for suffix in ["(band)", "(musician)", "(singer)", "(rapper)"] {
            if let img = await downloadSummaryImage(title: "\(query) \(suffix)") { imageCache[key]=img; Self.saveImageToDisk(key:key,image:img); return img }
        }
        // Try exact name, only accept if the summary is music-related
        if let r = await summaryData(title: query), isMusicRelated(r.extract),
           let img = await downloadSummaryImage(title: query) { imageCache[key]=img; Self.saveImageToDisk(key:key,image:img); return img }
        return nil
    }
    private struct SummaryResult { let extract: String; let imageURL: String? }
    private func summaryData(title: String) async -> SummaryResult? {
        let enc = title.replacingOccurrences(of:" ",with:"_").addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? title
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
    private func searchTitle(_ q: String) async -> String? {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [.init(name:"action",value:"query"),.init(name:"list",value:"search"),
                        .init(name:"srsearch",value:q),.init(name:"format",value:"json"),.init(name:"srlimit",value:"1")]
        guard let url = c.url, let (d, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let qr = j["query"] as? [String: Any], let sr = qr["search"] as? [[String: Any]],
              let t = sr.first?["title"] as? String else { return nil }
        return t
    }
}
