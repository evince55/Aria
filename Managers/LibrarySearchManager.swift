import Combine
import Foundation

/// State holder for the "Library" search scope ("Ask Your Library"):
/// owns the sync + query services, the scope's gating state, and the
/// `Loadable` results the search screen renders.
///
/// Injected via `.environmentObject` like every other manager (see
/// `App/AppEnvironment.swift`); wired to its peer managers through
/// `configure(...)` from `ContentView.onAppear` (the established pattern —
/// `playerManager.configureFavorites(...)` — managers never arrive through
/// view inits).
///
/// Scope gating (spec §5): the Library scope is visible only when
/// 1. `BackendConfig` resolves a URL (in this app "local-only mode" IS the
///    unconfigured state — there is no separate toggle), AND
/// 2. a `/api/health` probe this session reported a `library_index` block
///    (an older deployed backend without Slices 1–2 must hide the scope).
final class LibrarySearchManager: ObservableObject {
    /// Ranked results mapped back to the user's own `Track` objects.
    @Published private(set) var results: Loadable<[Track]> = .idle
    /// Retrieval mode of the last completed query: "hybrid" when the server's
    /// embedder answered, "lexical" when it degraded to BM25-only.
    @Published private(set) var mode: String?
    /// Whether the Library scope should be offered in the search UI.
    @Published private(set) var scopeAvailable = false

    let syncService: LibrarySyncService
    private let session: URLSessionProtocol
    private let resolveBaseURL: () -> String?
    private let resolveAPIKey: () -> String?
    private let now: () -> Date

    /// True once `/api/health` reported `library_index` this session.
    private(set) var healthProbeSawLibraryIndex = false
    /// The base URL the health probe last succeeded against (and the URL any
    /// synced data lives at) — the DELETE-on-URL-change target.
    private(set) var lastKnownBaseURL: String?

    private var favorites: FavoritesManager?
    private var playlists: PlaylistsManager?
    private var localLibrary: LocalLibraryManager?
    private var recents: RecentlyPlayedManager?

    private var mutationDebouncer: Debouncer!
    private var retryScheduled = false
    private var cancellables: Set<AnyCancellable> = []
    private var searchTask: Task<Void, Never>?

    init(
        syncService: LibrarySyncService? = nil,
        session: URLSessionProtocol = URLSessionAdapter(session: .shared),
        resolveBaseURL: @escaping () -> String? = {
            BackendConfig.isConfigured ? BackendConfig.baseURL : nil
        },
        resolveAPIKey: @escaping () -> String? = { BackendConfig.apiKey },
        now: @escaping () -> Date = Date.init
    ) {
        self.syncService = syncService ?? LibrarySyncService(
            session: session, resolveBaseURL: resolveBaseURL, resolveAPIKey: resolveAPIKey)
        self.session = session
        self.resolveBaseURL = resolveBaseURL
        self.resolveAPIKey = resolveAPIKey
        self.now = now
        self.mutationDebouncer = Debouncer(delay: 0.5) { [weak self] in
            self?.syncIfAllowed()
        }
    }

    // MARK: - Wiring

    /// Connects the peer managers (called once from `ContentView.onAppear`).
    /// Subscribes to their published mutations so any library change requests
    /// a debounced sync, and to the backend URL override for the privacy
    /// delete flow.
    func configure(
        favorites: FavoritesManager,
        playlists: PlaylistsManager,
        localLibrary: LocalLibraryManager,
        recents: RecentlyPlayedManager,
        settings: SettingsManager
    ) {
        guard self.favorites == nil else { return } // idempotent across onAppear re-fires
        self.favorites = favorites
        self.playlists = playlists
        self.localLibrary = localLibrary
        self.recents = recents

        favorites.$tracks.dropFirst()
            .sink { [weak self] _ in self?.libraryDidMutate() }
            .store(in: &cancellables)
        playlists.$playlists.dropFirst()
            .sink { [weak self] _ in self?.libraryDidMutate() }
            .store(in: &cancellables)
        localLibrary.$tracks.dropFirst()
            .sink { [weak self] _ in self?.libraryDidMutate() }
            .store(in: &cancellables)
        recents.$recentlyPlayed.dropFirst()
            .sink { [weak self] _ in self?.libraryDidMutate() }
            .store(in: &cancellables)
        settings.$backendURLOverride.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.backendURLDidChange() }
            .store(in: &cancellables)

        lastKnownBaseURL = resolveBaseURL()
    }

    /// App came to the foreground: re-probe health (a backend may have been
    /// deployed/woken since launch) and request a sync through the usual gate.
    func appDidBecomeActive() {
        Task { await probeHealth() }
        libraryDidMutate()
    }

    func flushPendingWrites() {
        syncService.flushPendingWrites()
    }

    // MARK: - Gating

    static func scopeVisible(backendConfigured: Bool, healthSawLibraryIndex: Bool) -> Bool {
        backendConfigured && healthSawLibraryIndex
    }

    private func updateScopeAvailable() {
        scopeAvailable = Self.scopeVisible(
            backendConfigured: resolveBaseURL() != nil,
            healthSawLibraryIndex: healthProbeSawLibraryIndex)
    }

    /// GETs `/api/health` and records whether the response carries a
    /// `library_index` block (Slice 1+ backend). Any failure leaves the
    /// scope hidden — never surface an error for a background probe.
    func probeHealth() async {
        guard let base = resolveBaseURL(), let url = URL(string: "\(base)/api/health") else {
            healthProbeSawLibraryIndex = false
            updateScopeAvailable()
            return
        }
        do {
            let (data, response) = try await session.data(
                for: .backendGET(url, apiKey: resolveAPIKey()))
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                throw URLError(.badServerResponse)
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            healthProbeSawLibraryIndex = (json?["library_index"] as? [String: Any]) != nil
            if healthProbeSawLibraryIndex { lastKnownBaseURL = base }
        } catch {
            healthProbeSawLibraryIndex = false
        }
        updateScopeAvailable()
    }

    // MARK: - Sync triggers

    /// Library mutation (or foreground): 0.5 s debounce, then the 60 s gate.
    func libraryDidMutate() {
        mutationDebouncer.call()
    }

    private func syncIfAllowed() {
        let currentTime = now()
        if LibrarySyncService.shouldSync(
            now: currentTime, lastAttempt: syncService.lastSyncAttemptAt) {
            Task { await performSync() }
        } else if !retryScheduled {
            // Trailing retry so a mutation that lands mid-gate isn't lost.
            retryScheduled = true
            let wait = LibrarySyncService.secondsUntilSyncAllowed(
                now: currentTime, lastAttempt: syncService.lastSyncAttemptAt)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.retryScheduled = false
                self?.syncIfAllowed()
            }
        }
    }

    private func performSync() async {
        guard resolveBaseURL() != nil else { return }
        let snapshot = currentSnapshot()
        // Sync failures are silent by design: the delta is retried on the
        // next mutation/foreground because syncedHashes only advance on
        // success.
        try? await syncService.sync(snapshot: snapshot)
    }

    private func currentSnapshot() -> [LibraryTrackDoc] {
        LibrarySyncService.buildSnapshot(
            favorites: favorites?.tracks ?? [],
            playlists: playlists?.playlists ?? [],
            localTracks: localLibrary?.tracks ?? [],
            recentlyPlayed: recents?.recentlyPlayed ?? [],
            playStats: recents?.playStats ?? [:],
            now: now())
    }

    // MARK: - Query

    /// Runs a library query and maps the returned track_ids back onto the
    /// user's own tracks. Results keep the server's ranking; ids that no
    /// longer exist locally are dropped.
    func search(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = .idle
            return
        }
        guard let base = resolveBaseURL() else {
            results = .idle
            return
        }
        results = .loading
        let service = LibrarySearchService(
            backendURL: base, session: session, apiKey: resolveAPIKey())
        let deviceID = syncService.deviceID
        searchTask = Task { [weak self] in
            do {
                let response = try await service.query(deviceID: deviceID, q: trimmed)
                guard let self, !Task.isCancelled else { return }
                let byID = self.tracksByID()
                self.mode = response.mode
                self.results = .loaded(response.results.compactMap { byID[$0.trackID] })
            } catch is CancellationError {
                // Superseded by a newer query; keep the current state.
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.results = .failed(error)
            }
        }
    }

    func clearResults() {
        searchTask?.cancel()
        results = .idle
        mode = nil
    }

    /// track_id → playable `Track` across every library source. Local imports
    /// resolve through `LocalLibraryManager` so the mapped track carries a
    /// current-container file URL.
    private func tracksByID() -> [String: Track] {
        var map: [String: Track] = [:]
        if let localLibrary {
            for local in localLibrary.tracks where !local.isMissing {
                let track = local.asPlayerTrack(fileURL: localLibrary.fileURL(for: local))
                map[track.id] = track
            }
        }
        for track in favorites?.tracks ?? [] where map[track.id] == nil {
            map[track.id] = track
        }
        for playlist in playlists?.playlists ?? [] {
            for track in playlist.tracks where map[track.id] == nil {
                map[track.id] = track
            }
        }
        for track in recents?.recentlyPlayed ?? [] where map[track.id] == nil {
            map[track.id] = track
        }
        return map
    }

    // MARK: - Privacy: backend URL changed

    /// The user cleared or changed the backend URL in Settings. Fire a
    /// best-effort `DELETE /api/library?device_id=` at the OLD backend and
    /// clear local synced-hash state so a future backend starts fresh
    /// (spec §10 step 6). Never blocks the UI.
    func backendURLDidChange() {
        let old = lastKnownBaseURL
        let new = resolveBaseURL()
        lastKnownBaseURL = new
        healthProbeSawLibraryIndex = false
        clearResults()
        updateScopeAvailable()
        Task { [weak self] in
            guard let self else { return }
            await self.syncService.deleteRemoteAndReset(
                oldBaseURL: old == new ? nil : old)
            if new != nil {
                await self.probeHealth()
                self.libraryDidMutate() // seed the new backend
            }
        }
    }
}
