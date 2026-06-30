import XCTest
@testable import Aria___Music_Browser

/// Counting `StreamResolving` double so tests can assert how many times the
/// underlying resolver was actually hit.
private final class CountingResolver: StreamResolving, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var resolveCount = 0

    func stream(for videoID: String) async throws -> URL {
        URL(string: "https://example.com/\(videoID)")!
    }

    func resolve(for videoID: String) async throws -> ResolvedStream {
        lock.lock(); resolveCount += 1; lock.unlock()
        return ResolvedStream(url: URL(string: "https://example.com/\(videoID).m4a")!, duration: 123)
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
}
