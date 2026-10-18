import Foundation

/// Cross-app title search via JustWatch's public GraphQL API (India catalogue, no key needed).
/// Each result carries one TV-openable link per streaming app. We keep offers whose URL host is
/// one the TV apps' intent filters claim (docs/DEEPLINKS.md); JustWatch's own ANDROID_TV
/// deeplinks are `intent://` URIs, which the remote service rejects, so we use standardWebURL.
enum JustWatch {
    struct Offer: Identifiable, Hashable {
        let app: StreamingApp
        let url: String
        let label: String       // Stream, Free, Ads, Rent, Buy
        var id: String { app.id }
    }

    struct Title: Identifiable {
        let id: String
        let name: String
        let year: Int?
        let isShow: Bool
        let poster: URL?
        let offers: [Offer]
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

    static func search(_ text: String, country: String = "IN") async throws -> [Title] {
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

        return decoded.data.popularTitles.edges.map { edge in
            let node = edge.node
            // Best offer per app: subscription beats free beats ads beats rent/buy.
            var best: [String: (rank: Int, offer: Offer)] = [:]
            for o in node.offers {
                guard let host = URL(string: o.standardWebURL)?.host,
                      let pkg = appForHost[host], let app = apps[pkg] else { continue }
                let r = rank[o.monetizationType] ?? 9
                if let current = best[pkg], current.rank <= r { continue }
                best[pkg] = (r, Offer(app: app, url: o.standardWebURL,
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
