import Foundation
import Network

/// Finds Android TVs on the LAN over Bonjour. Browses the remote service itself
/// (_androidtvremote2._tcp) and Chromecast (_googlecast._tcp): the Acer R4 doesn't advertise the
/// former even though ports 6466/6467 are open, but every Google TV advertises the latter.
public final class TVDiscovery {
    public static let serviceTypes = ["_androidtvremote2._tcp", "_googlecast._tcp"]

    public struct Found: Hashable, Identifiable {
        public let name: String
        public let endpoint: NWEndpoint
        public var id: String { name }
    }

    public var onChange: (([Found]) -> Void)?
    private var browsers: [NWBrowser] = []
    private var results: [String: [Found]] = [:]   // per service type

    public init() {}

    public func start() {
        stop()
        for type in Self.serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] found, _ in
                guard let self else { return }
                self.results[type] = found.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return Found(name: name, endpoint: result.endpoint)
                }
                self.publish()
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        results = [:]
    }

    private func publish() {
        var seen = Set<String>()
        let merged = Self.serviceTypes.flatMap { results[$0] ?? [] }.filter { seen.insert($0.name).inserted }
        onChange?(merged.sorted { $0.name < $1.name })
    }

    /// Resolves a Bonjour service to its IP address (the advertised port is irrelevant: we always
    /// talk to 6467 for pairing and 6466 for remote control on the same host).
    public static func resolveHost(_ endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { cont in
            let params = NWParameters.tcp
            (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            let conn = NWConnection(to: endpoint, using: params)
            var done = false
            conn.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    var host: String?
                    if case let .hostPort(h, _) = conn.currentPath?.remoteEndpoint {
                        switch h {
                        case .ipv4(let a): host = "\(a)"
                        case .ipv6(let a): host = "\(a)"
                        case .name(let n, _): host = n
                        @unknown default: host = nil
                        }
                    }
                    conn.cancel()
                    cont.resume(returning: host?.components(separatedBy: "%").first)
                case .failed, .waiting:
                    done = true
                    conn.cancel()
                    cont.resume(returning: nil)
                default: break
                }
            }
            conn.start(queue: .global())
        }
    }
}
