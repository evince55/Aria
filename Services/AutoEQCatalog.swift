import Combine
import Foundation

/// Backs the AutoEQ browser: loads the bundled headphone index, filters it,
/// and fetches a selected entry's `ParametricEQ.txt` from the AutoEq repo's
/// raw-content CDN. The index ships in the app (search is instant/offline);
/// only the final ~1 KB profile fetch needs the network.
final class AutoEQCatalog: ObservableObject {
    enum CatalogError: LocalizedError {
        case indexMissing
        case badURL
        case badStatus(Int)
        case notText

        var errorDescription: String? {
            switch self {
            case .indexMissing: return "The bundled AutoEQ index is missing."
            case .badURL: return "Couldn't build the profile URL."
            case .badStatus(let code): return "AutoEQ fetch failed (HTTP \(code)). Check your connection and try again."
            case .notText: return "The downloaded profile wasn't readable text."
            }
        }
    }

    @Published private(set) var index: Loadable<[AutoEQCatalogEntry]> = .idle

    private let urlSession: URLSessionProtocol

    init(urlSession: URLSessionProtocol = AutoEQCatalog.defaultSession()) {
        self.urlSession = urlSession
    }

    static func defaultSession() -> URLSessionProtocol {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSessionAdapter(session: URLSession(configuration: config))
    }

    /// Decodes the bundled index off the main actor (8,850 entries) and
    /// publishes it. Safe to call repeatedly; only the first call does work.
    func loadIndexIfNeeded() {
        guard case .idle = index else { return }
        index = .loading
        Task.detached(priority: .userInitiated) {
            do {
                let entries = try Self.decodeBundledIndex()
                await MainActor.run { self.index = .loaded(entries) }
            } catch {
                await MainActor.run { self.index = .failed(error) }
            }
        }
    }

    /// Synchronous decode of `Resources/autoeq-index.json`. Separated (and
    /// nonisolated) so tests can call it directly.
    nonisolated static func decodeBundledIndex() throws -> [AutoEQCatalogEntry] {
        guard let url = Bundle.main.url(forResource: "autoeq-index", withExtension: "json") else {
            throw CatalogError.indexMissing
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([AutoEQCatalogEntry].self, from: data)
    }

    /// Pure filter: every whitespace-separated token must match the name or
    /// source (case-insensitive), optionally narrowed to one form factor.
    /// The index is pre-sorted (name, then source priority), so results keep
    /// a stable, sensible order.
    nonisolated static func filter(
        _ entries: [AutoEQCatalogEntry],
        query: String,
        formFactor: AutoEQCatalogEntry.FormFactor?
    ) -> [AutoEQCatalogEntry] {
        var result = entries
        if let formFactor {
            result = result.filter { $0.formFactor == formFactor }
        }
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return result }
        return result.filter { entry in
            let haystack = "\(entry.name.lowercased()) \(entry.source.lowercased())"
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    /// Fetches and parses the entry's parametric profile.
    func fetchProfile(for entry: AutoEQCatalogEntry) async throws -> ParametricEQPreset {
        guard let url = entry.profileURL else { throw CatalogError.badURL }
        let (data, response) = try await urlSession.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.badStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CatalogError.notText }
        return try AutoEQParser.parse(text, name: entry.name)
    }
}
