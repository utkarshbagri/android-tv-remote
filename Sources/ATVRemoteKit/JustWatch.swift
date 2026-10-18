import Foundation

/// Cross-app title search via JustWatch's public GraphQL API (India catalogue, no key needed).
/// Each result carries one TV-openable link per streaming app. We keep offers whose URL host is
/// one the TV apps' intent filters claim (docs/DEEPLINKS.md); JustWatch's own ANDROID_TV
/// deeplinks are `intent://` URIs, which the remote service rejects, so we use standardWebURL.
public enum JustWatch {
    public struct Offer: Identifiable, Hashable {
        public let app: StreamingApp
        public let url: String
        public let label: String       // Stream, Free, Ads, Rent, Buy
        public var id: String { app.id }

        public init(app: StreamingApp, url: String, label: String) {
            self.app = app
            self.url = url
            self.label = label
        }
    }

    public struct Title: Identifiable {
        public let id: String
        public let name: String
        public let year: Int?
        public let isShow: Bool
        public let poster: URL?
        public let offers: [Offer]
    }

    /// URL host → the installed TV app that opens it.
    private static let appForHost: [String: String] = [
        "www.netflix.com": "com.netflix.ninja",
        "app.primevideo.com": "com.amazon.amazonvideo.livingroom",
        "www.hotstar.com": "in.startv.hotstar",
        "www.sonyliv.com": "com.sonyliv",
        "tv.apple.com": "com.apple.atve.androidtv.appletv",
        "www.youtube.com": "com.google.android.youtube.tv",
    ]

    private static let rank = ["FLATRATE": 0, "FREE": 1, "ADS": 2, "RENT": 3, "BUY": 4]
    private static let labels = ["FLATRATE": "Stream", "FREE": "Free", "ADS": "Ads", "RENT": "Rent", "BUY": "Buy"]

    private static let query = """
    query Search($country: Country!, $language: Language!, $first: Int!, $filter: TitleFilter) {
      popularTitles(country: $country, first: $first, filter: $filter) {
        edges { node { id objectType
          content(country: $country, language: $language) { title originalReleaseYear posterUrl }
          offers(country: $country, platform: WEB) { monetizationType standardWebURL }
        } }
      }
    }
    """

    public static func search(_ text: String, country: String = "IN") async throws -> [Title] {
        var request = URLRequest(url: URL(string: "https://apis.justwatch.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "operationName": "Search",
            "query": query,
            "variables": ["country": country, "language": "en", "first": 12,
                          "filter": ["searchQuery": text]],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let apps = Dictionary(uniqueKeysWithValues: streamingApps.map { ($0.id, $0) })

        let titles = decoded.data.popularTitles.edges.map { edge in
            let node = edge.node
            // Best offer per app: subscription beats free beats ads beats rent/buy.
            var best: [String: (rank: Int, offer: Offer)] = [:]
            for o in node.offers {
                guard let url = URL(string: o.standardWebURL), let host = url.host,
                      let pkg = appForHost[host], let app = apps[pkg],
                      isTitleLink(url) else { continue }
                let r = rank[o.monetizationType] ?? 9
                if let current = best[pkg], current.rank <= r { continue }
                best[pkg] = (r, Offer(app: app, url: tvLink(o.standardWebURL, host: host),
                                      label: labels[o.monetizationType] ?? o.monetizationType.capitalized))
            }
            let offers = best.values.sorted { $0.rank < $1.rank }.map(\.offer)
            let poster = node.content.posterUrl.flatMap {
                URL(string: "https://images.justwatch.com" + $0
                    .replacingOccurrences(of: "{profile}", with: "s166")
                    .replacingOccurrences(of: "{format}", with: "jpg"))
            }
            return Title(id: node.id, name: node.content.title, year: node.content.originalReleaseYear,
                         isShow: node.objectType == "SHOW", poster: poster, offers: offers)
        }
        // Keep JustWatch's relevance order, but titles we can't open go last.
        return titles.filter { !$0.offers.isEmpty } + titles.filter { $0.offers.isEmpty }
    }

    /// Some offers link to a store front, not the title. E.g. Raanjhanaa's Apple TV "Eros Now"
    /// channel offer is just `https://tv.apple.com/in`, which drops you on Apple TV's home.
    /// A title link has more in its path than a country code.
    public static func isTitleLink(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/")
        return !(parts.isEmpty || (parts.count == 1 && parts[0].count == 2))
    }

    /// Netflix's TV app ignores deep links unless they carry `source=30`. The usual route is an
    /// intent extra, but the remote service sends a bare VIEW intent, so it has to go in the URL
    /// (confirmed on the R4: the plain title link stays on Home, `?source=30` opens the title).
    public static func tvLink(_ url: String, host: String) -> String {
        guard host == "www.netflix.com", !url.contains("source=") else { return url }
        return url + (url.contains("?") ? "&" : "?") + "source=30"
    }

    private struct Response: Decodable {
        struct Data: Decodable { let popularTitles: Popular }
        struct Popular: Decodable { let edges: [Edge] }
        struct Edge: Decodable { let node: Node }
        struct Node: Decodable {
            let id: String
            let objectType: String
            let content: Content
            let offers: [RawOffer]
        }
        struct Content: Decodable {
            let title: String
            let originalReleaseYear: Int?
            let posterUrl: String?
        }
        struct RawOffer: Decodable {
            let monetizationType: String
            let standardWebURL: String
        }
        let data: Data
    }
}
