import Foundation

/// Streaming apps we can open on the TV. Links are the "app home" URLs each TV app's intent
/// filters claim (verified on the Acer R4, see docs/DEEPLINKS.md). F1 TV declares no deep links
/// and can't be launched over the remote protocol, so it isn't here.
public struct StreamingApp: Identifiable, Hashable {
    public let id: String          // Android package
    public let name: String
    public let symbol: String
    public let link: String

    public init(id: String, name: String, symbol: String, link: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.link = link
    }

    /// Compact label for result chips.
    public var shortName: String { name == "Prime Video" ? "Prime" : name }

    /// Apps with a "Who's watching?" picker that can drop a deep link on a cold start (Netflix and
    /// Apple TV reported by the user, Prime likewise), so the link is re-sent after the profile pick.
    public var hasProfilePicker: Bool { Self.profileGated.contains(id) }

    private static let profileGated: Set<String> = [
        "com.netflix.ninja", "com.apple.atve.androidtv.appletv", "com.amazon.amazonvideo.livingroom",
    ]
}

public let streamingApps: [StreamingApp] = [
    .init(id: "com.netflix.ninja", name: "Netflix", symbol: "n.square.fill",
          link: "https://www.netflix.com/browse"),
    .init(id: "com.amazon.amazonvideo.livingroom", name: "Prime Video", symbol: "play.square.fill",
          link: "https://app.primevideo.com/"),
    .init(id: "in.startv.hotstar", name: "JioHotstar", symbol: "star.square.fill",
          link: "https://www.hotstar.com/in/home"),
    .init(id: "com.google.android.youtube.tv", name: "YouTube", symbol: "play.rectangle.fill",
          link: "https://www.youtube.com/"),
    .init(id: "com.sonyliv", name: "SonyLIV", symbol: "s.square.fill",
          link: "https://www.sonyliv.com/"),
    .init(id: "com.apple.atve.androidtv.appletv", name: "Apple TV", symbol: "appletv.fill",
          link: "https://tv.apple.com/"),
]

/// Friendly name for the TV's foreground package ("Now on" readouts).
public func appName(forPackage pkg: String) -> String {
    if pkg.isEmpty { return "—" }
    return knownPackages[pkg] ?? pkg.components(separatedBy: ".").last ?? pkg
}

private let knownPackages: [String: String] = Dictionary(
    uniqueKeysWithValues: streamingApps.map { ($0.id, $0.name) } + [
        ("com.formulaone.production", "F1 TV"),
        ("com.gathin.tvhome", "Home"),
        ("com.google.android.youtube.tvmusic", "YouTube Music"),
    ])

/// A title link sent to a profile-gated app, kept so it can be re-sent once a profile is picked:
/// automatically `resendDelay` after the next OK, or from an "Open title again" prompt shown for
/// `promptWindow`. Re-sending once the title page is already showing is harmless.
public struct PendingLink: Equatable {
    public let url: String
    public let title: String
    public let appName: String
    private let token = UUID()

    public static let resendDelay: UInt64 = 3_000_000_000      // ns after OK
    public static let promptWindow: UInt64 = 90_000_000_000    // ns

    /// nil when the offer's app has no profile picker.
    public init?(offer: JustWatch.Offer, title: String) {
        guard offer.app.hasProfilePicker else { return nil }
        url = offer.url
        self.title = title
        appName = offer.app.shortName
    }
}
