import XCTest
@testable import Aria___Music_Browser

/// Counting `StreamResolving` double so tests can assert how many times the
/// underlying resolver was actually hit.
private final class CountingResolver: StreamResolving, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var resolveCount = 0
    private(set) var freshCount = 0

    func stream(for videoID: String) async throws -> URL {
        URL(string: "https://example.com/\(videoID)")!
    }

    func resolve(for videoID: String) async throws -> ResolvedStream {
        lock.lock(); resolveCount += 1; lock.unlock()
        return ResolvedStream(url: URL(string: "https://example.com/\(videoID).m4a")!, duration: 123)
    }

    func resolve(for videoID: String, fresh: Bool) async throws -> ResolvedStream {
        if fresh { lock.lock(); freshCount += 1; lock.unlock() }
        return try await resolve(for: videoID)
    }
}

private final class TimeBox: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 0)
}

final class StreamPrefetcherTests: XCTestCase {

    func test_resolveWithoutPrefetch_callsUnderlyingResolver() async throws {
        let resolver = CountingResolver()
        let prefetcher = StreamPrefetcher(resolver: resolver)

        let stream = try await prefetcher.resolve(for: "abc")

        XCTAssertEqual(resolver.resolveCount, 1)
        XCTAssertEqual(stream.url.absoluteString, "https://example.com/abc.m4a")
    }

    func test_prefetchThenResolve_servesFromCacheWithoutResolvingAgain() async throws {
        let resolver = CountingResolver()
        let prefetcher = StreamPrefetcher(resolver: resolver)

        await prefetcher.prefetch("abc")
        await prefetcher.waitForPrefetch()
        XCTAssertEqual(resolver.resolveCount, 1, "prefetch should resolve once")

        let stream = try await prefetcher.resolve(for: "abc")
        XCTAssertEqual(resolver.resolveCount, 1, "resolve should hit the cache, not the network")
        XCTAssertEqual(stream.url.absoluteString, "https://example.com/abc.m4a")
    }

    func test_resolveConsumesCache_secondResolveReResolves() async throws {
        let resolver = CountingResolver()
        let prefetcher = StreamPrefetcher(resolver: resolver)

        await prefetcher.prefetch("abc")
        await prefetcher.waitForPrefetch()

        _ = try await prefetcher.resolve(for: "abc")  // consumes the entry
        _ = try await prefetcher.resolve(for: "abc")  // cache empty → re-resolves
        XCTAssertEqual(resolver.resolveCount, 2)
    }

    func test_expiredEntry_fallsThroughToResolver() async throws {
        let resolver = CountingResolver()
        let box = TimeBox()
        let prefetcher = StreamPrefetcher(resolver: resolver, ttl: 60, now: { box.now })

        await prefetcher.prefetch("abc")
        await prefetcher.waitForPrefetch()
        XCTAssertEqual(resolver.resolveCount, 1)

        box.now = Date(timeIntervalSince1970: 120)  // past the 60s TTL
        _ = try await prefetcher.resolve(for: "abc")
        XCTAssertEqual(resolver.resolveCount, 2, "expired cache entry should be ignored")
    }

    func test_resolveForDifferentID_doesNotUsePrefetchedEntry() async throws {
        let resolver = CountingResolver()
        let prefetcher = StreamPrefetcher(resolver: resolver)

        await prefetcher.prefetch("abc")
        await prefetcher.waitForPrefetch()

        _ = try await prefetcher.resolve(for: "different")
        XCTAssertEqual(resolver.resolveCount, 2, "a different id must not be served from abc's cache")
    }

    func test_batchPrefetch_warmsAllUpcoming() async throws {
        let resolver = CountingResolver()
        let prefetcher = StreamPrefetcher(resolver: resolver)

        await prefetcher.prefetch(["a", "b", "c"])
        await prefetcher.waitForPrefetch()
        XCTAssertEqual(resolver.resolveCount, 3, "all three upcoming tracks should be warmed")

        _ = try await prefetcher.resolve(for: "a")
        _ = try await prefetcher.resolve(for: "b")
        _ = try await prefetcher.resolve(for: "c")
        XCTAssertEqual(resolver.resolveCount, 3, "all three should be served from cache")
    }

    func test_freshResolve_bypassesWarmCacheAndPropagatesFresh() async throws {
        let resolver = CountingResolver()
        let prefetcher = StreamPrefetcher(resolver: resolver)

        await prefetcher.prefetch("abc")
        await prefetcher.waitForPrefetch()
        XCTAssertEqual(resolver.resolveCount, 1)

        // Failure recovery: the warm entry may hold the exact URL that just
        // died — it must be dropped and the resolve forced through fresh.
        _ = try await prefetcher.resolve(for: "abc", fresh: true)
        XCTAssertEqual(resolver.resolveCount, 2, "fresh must not serve the cached entry")
        XCTAssertEqual(resolver.freshCount, 1, "fresh must propagate to the underlying resolver")
    }

    func test_nonFreshResolve_keepsCacheSemantics() async throws {
        let resolver = CountingResolver()
        let prefetcher = StreamPrefetcher(resolver: resolver)

        await prefetcher.prefetch("abc")
        await prefetcher.waitForPrefetch()

        _ = try await prefetcher.resolve(for: "abc", fresh: false)
        XCTAssertEqual(resolver.resolveCount, 1, "fresh:false behaves exactly like the cached path")
        XCTAssertEqual(resolver.freshCount, 0)
    }

    func test_batchPrefetch_dropsEntriesNoLongerUpcoming() async throws {
        let resolver = CountingResolver()
        let prefetcher = StreamPrefetcher(resolver: resolver)

        await prefetcher.prefetch(["a", "b", "c"])
        await prefetcher.waitForPrefetch()

        // Queue moved on to [c, d]: a and b drop, c stays warm, d is added.
        await prefetcher.prefetch(["c", "d"])
        await prefetcher.waitForPrefetch()
        XCTAssertEqual(resolver.resolveCount, 4, "only d is newly resolved; c stayed cached")

        _ = try await prefetcher.resolve(for: "a")  // dropped → re-resolves
        XCTAssertEqual(resolver.resolveCount, 5)
        _ = try await prefetcher.resolve(for: "c")  // still warm
        XCTAssertEqual(resolver.resolveCount, 5)
    }
}
