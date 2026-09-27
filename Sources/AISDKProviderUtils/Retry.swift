import Foundation

/// Why retrying stopped. Mirrors upstream `RetryErrorReason`.
public enum RetryErrorReason: String, Sendable, Hashable {
  case maxRetriesExceeded
  case errorNotRetryable
}

/// Sleeps for the given number of milliseconds. Mirrors upstream `delay`.
///
/// - Throws: `CancellationError` when the task is cancelled.
public func delay(_ delayInMs: Double?) async throws {
  guard let delayInMs, delayInMs > 0 else { return }
  try await Task.sleep(nanoseconds: UInt64(delayInMs * 1_000_000))
}

/// Retries an operation with exponential backoff. Mirrors upstream
/// `retryWithExponentialBackoff`.
///
/// Cancellation is never retried. With `maxRetries == 0`, errors pass through
/// unwrapped.
public struct RetryWithExponentialBackoff: Sendable {
  public typealias ShouldRetry = @Sendable (any Error) async -> Bool
  public typealias DelayProvider = @Sendable (_ error: any Error, _ exponentialBackoffDelay: Double) -> Double
  public typealias RetryErrorFactory =
    @Sendable (_ message: String, _ reason: RetryErrorReason, _ errors: [any Error]) -> any Error

  public var maxRetries: Int
  public var initialDelayInMs: Double
  public var backoffFactor: Double
  public var shouldRetry: ShouldRetry
  public var getDelayInMs: DelayProvider
  public var createRetryError: RetryErrorFactory

  public init(
    maxRetries: Int = 2,
    initialDelayInMs: Double = 2000,
    backoffFactor: Double = 2,
    shouldRetry: @escaping ShouldRetry,
    getDelayInMs: @escaping DelayProvider = { _, exponentialBackoffDelay in exponentialBackoffDelay },
    createRetryError: @escaping RetryErrorFactory = { message, _, _ in GenericRetryError(message: message) }
  ) {
    self.maxRetries = maxRetries
    self.initialDelayInMs = initialDelayInMs
    self.backoffFactor = backoffFactor
    self.shouldRetry = shouldRetry
    self.getDelayInMs = getDelayInMs
    self.createRetryError = createRetryError
  }

  public func callAsFunction<Output>(_ operation: () async throws -> Output) async throws -> Output {
    var errors: [any Error] = []
    var delayInMs = initialDelayInMs

    while true {
      do {
        return try await operation()
      } catch {
        if isCancellationError(error) || maxRetries == 0 {
          throw error
        }

        let errorMessage = getErrorMessage(error)
        errors.append(error)
        let tryNumber = errors.count

        if tryNumber > maxRetries {
          throw createRetryError(
            "Failed after \(tryNumber) attempts. Last error: \(errorMessage)",
            .maxRetriesExceeded, errors)
        }

        if await shouldRetry(error) {
          try await delay(getDelayInMs(error, delayInMs))
          delayInMs *= backoffFactor
          continue
        }

        if tryNumber == 1 {
          throw error
        }

        throw createRetryError(
          "Failed after \(tryNumber) attempts with non-retryable error: '\(errorMessage)'",
          .errorNotRetryable, errors)
      }
    }
  }
}

/// The default error thrown by `RetryWithExponentialBackoff` when retries are exhausted.
public struct GenericRetryError: AISDKError {
  public let name = "AI_RetryError"
  public let message: String

  public init(message: String) {
    self.message = message
  }
}
