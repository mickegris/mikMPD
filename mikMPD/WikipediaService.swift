import Foundation
actor WikipediaService {
    static let shared = WikipediaService()
    private var cache: [String: String] = [:]
    func fetch(query: String) async -> String? {
        if let c = cache[query] { return c.isEmpty ? nil : c }
        if let t = await summary(title: query), !t.isEmpty { cache[query]=t; return t }
        if let ttl = await searchTitle(query), let t = await summary(title:ttl), !t.isEmpty { cache[query]=t; return t }
        cache[query]=""; return nil
    }
    private func summary(title: String) async -> String? {
        let enc = title.replacingOccurrences(of:" ",with:"_").addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? title
        guard let url=URL(string:"https://en.wikipedia.org/api/rest_v1/page/summary/\(enc)"),
              let (d,r)=try? await URLSession.shared.data(from:url),(r as? HTTPURLResponse)?.statusCode==200,
              let j=try? JSONSerialization.jsonObject(with:d) as? [String:Any],
              let t=j["extract"] as? String,!t.isEmpty,(j["type"] as? String) != "disambiguation"
        else { return nil }; return t
    }
    private func searchTitle(_ q: String) async -> String? {
        var c=URLComponents(string:"https://en.wikipedia.org/w/api.php")!
        c.queryItems=[.init(name:"action",value:"query"),.init(name:"list",value:"search"),.init(name:"srsearch",value:q),.init(name:"format",value:"json"),.init(name:"srlimit",value:"1")]
        guard let url=c.url,let (d,_)=try? await URLSession.shared.data(from:url),
              let j=try? JSONSerialization.jsonObject(with:d) as? [String:Any],
              let qr=j["query"] as? [String:Any],let sr=qr["search"] as? [[String:Any]],
              let t=sr.first?["title"] as? String else { return nil }; return t
    }
}
