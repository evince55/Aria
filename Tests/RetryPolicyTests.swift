import XCTest
@testable import Aria___Music_Browser

final class RetryPolicyTests: XCTestCase {

    // MARK: - Classification

    func test_isRetryable_transientNetworkErrors() {
        XCTAssertTrue(RetryPolicy.isRetryableNetworkError(URLError(.timedOut)))
        XCTAssertTrue(RetryPolicy.isRetryableNetworkError(URLError(.cannotConnectToHost)))
        XCTAssertTrue(RetryPolicy.isRetryableNetworkError(URLError(.networkConnectionLost)))
    }

    func test_isRetryable_gatewayStatuses() {
        XCTAssertTrue(RetryPolicy.isRetryableNetworkError(RetryPolicy.RetryableHTTPStatus(statusCode: 502)))
        XCTAssertTrue(RetryPolicy.isRetryableNetworkError(RetryPolicy.RetryableHTTPStatus(statusCode: 503)))
    }

    func test_isNotRetryable_clientErrorsAndBadURL() {
        XCTAssertFalse(RetryPolicy.isRetryableNetworkError(RetryPolicy.RetryableHTTPStatus(statusCode: 404)))
        XCTAssertFalse(RetryPolicy.isRetryableNetworkError(URLError(.badURL)))
        XCTAssertFalse(RetryPolicy.isRetryableNetworkError(StreamResolverError.malformedResponse))
    }

    // MARK: - withRetry

    func test_withRetry_retriesTransientThenSucceeds() async throws {
        var attempts = 0
        let result = try await withRetry(maxAttempts: 3, baseDelay: 0) { () -> String in
            attempts += 1
            if attempts < 2 { throw URLError(.timedOut) }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 2)
    }

    func test_withRetry_retriesUpToMaxThenThrows() async {
        var attempts = 0
        do {
            _ = try await withRetry(maxAttempts: 3, baseDelay: 0) { () -> String in
                attempts += 1
                throw URLError(.timedOut)
            }
            XCTFail("expected the last error to propagate")
        } catch {
            XCTAssertTrue(error is URLError)
        }
        XCTAssertEqual(attempts, 3)
    }

    func test_withRetry_doesNotRetryNonRetryableError() async {
        var attempts = 0
        do {
            _ = try await withRetry(maxAttempts: 3, baseDelay: 0) { () -> String in
                attempts += 1
                throw RetryPolicy.RetryableHTTPStatus(statusCode: 404)
            }
            XCTFail("expected throw")
        } catch {
            // 404 is not retryable
        }
        XCTAssertEqual(attempts, 1, "a 4xx must not be retried")
    }

    func test_withRetry_retries503() async throws {
        var attempts = 0
        let result = try await withRetry(maxAttempts: 4, baseDelay: 0) { () -> String in
            attempts += 1
            if attempts < 3 { throw RetryPolicy.RetryableHTTPStatus(statusCode: 503) }
            return "up"
        }
        XCTAssertEqual(result, "up")
        XCTAssertEqual(attempts, 3)
    }
}
