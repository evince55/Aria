import Foundation

/// Retry helper for the networking layer. Wraps a throwing async operation and
/// retries it with exponential backoff on *transient* failures only — the
/// dominant one being a Render free-tier cold start (~30–60 s spin-up), which
/// surfaces as request timeouts and 502/503 while the instance wakes.
///
/// Default schedule with `maxAttempts: 3`, `baseDelay: 1`: sleeps ~1 s then
/// ~3 s between the three attempts (1·3^0, 1·3^1), giving the backend time to
/// come up before the last try. Backs off honoring `Task` cancellation.
enum RetryPolicy {
    /// Throwable that carries an HTTP status so `isRetryableNetworkError` can
    /// treat 502/503 as transient. Callers that validate responses inside the
    /// retried closure should throw this for retryable statuses.
    struct RetryableHTTPStatus: LocalizedError {
        let statusCode: Int
        var errorDescription: String? {
            "The server is starting up (HTTP \(statusCode)). Please try again in a moment."
        }
    }

    /// True for errors worth retrying: connection/timeout `URLError`s and
    /// 502/503 gateway statuses. Never 4xx, never decode/malformed errors.
    static func isRetryableNetworkError(_ error: Error) -> Bool {
        if let status = error as? RetryableHTTPStatus {
            return status.statusCode == 502 || status.statusCode == 503
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            // Transient transport / server-not-ready-yet signals — the shape of
            // a Render free-tier cold start. Deliberately NOT
            // `.notConnectedToInternet`: a genuinely offline device should fail
            // fast, not wait out the backoff.
            case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                 .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}

/// Runs `operation`, retrying up to `maxAttempts` total times while
/// `isRetryable` says the error is transient, sleeping `baseDelay * 3^n`
/// seconds before attempt `n+1`. Re-throws the last error once attempts are
/// exhausted or the error isn't retryable. Cancellation is respected both
/// during the operation and during backoff.
func withRetry<T>(
    maxAttempts: Int = 3,
    baseDelay: TimeInterval = 1,
    isRetryable: (Error) -> Bool = RetryPolicy.isRetryableNetworkError,
    _ operation: () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            attempt += 1
            if attempt >= maxAttempts || !isRetryable(error) {
                throw error
            }
            let delay = baseDelay * pow(3, Double(attempt - 1))
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
