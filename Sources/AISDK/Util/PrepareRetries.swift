import Foundation

/// Reads a retry delay from `retry-after-ms` or `retry-after` headers, falling
/// back to exponential backoff when absent or unreasonable.
/// Mirrors upstream `getRetryDelayInMs`.
func retryDelayInMs(error: any Error, exponentialBackoffDelay: Double, now: Date = Date()) -> Double {
  guard let headers = (error as? APICallError)?.responseHeaders else { return exponentialBackoffDelay }

  var ms: Double?
  if let retryAfterMs = headers["retry-after-ms"], let value = Double(retryAfterMs) {
    ms = value
  }
  if ms == nil, let retryAfter = headers["retry-after"] {
    if let seconds = Double(retryAfter) {
      ms = seconds * 1000
    } else if let date = parseHTTPDate(retryAfter) {
      ms = date.timeIntervalSince(now) * 1000
    }
  }

  if let ms, ms >= 0, ms < 60_000 || ms < exponentialBackoffDelay {
    return ms
  }
  return exponentialBackoffDelay
}

private func parseHTTPDate(_ value: String) -> Date? {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(identifier: "GMT")
  formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
  return formatter.date(from: value)
}

/// Retries retryable `APICallError`s with exponential backoff, honoring retry
/// headers. Mirrors upstream `retryWithExponentialBackoffRespectingRetryHeaders`.
func prepareRetries(maxRetries: Int, initialDelayInMs: Double = 2000) -> RetryWithExponentialBackoff {
  RetryWithExponentialBackoff(
    maxRetries: maxRetries,
    initialDelayInMs: initialDelayInMs,
    backoffFactor: 2,
    shouldRetry: { error in (error as? APICallError)?.isRetryable == true },
    getDelayInMs: { error, delay in retryDelayInMs(error: error, exponentialBackoffDelay: delay) },
    createRetryError: { message, reason, errors in RetryError(message: message, reason: reason, errors: errors) })
}
