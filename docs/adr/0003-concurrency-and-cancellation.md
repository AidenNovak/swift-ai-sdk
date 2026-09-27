# 0003. Concurrency, streaming and cancellation

- Status: accepted
- Date: 2026-09-27

## Decision

- The package uses the Swift 6 language mode with complete concurrency checking. Every public type is `Sendable`.
- Upstream `ReadableStream<T>` maps to `AsyncThrowingStream<T, any Error>`.
- Upstream `AbortSignal` maps to structured `Task` cancellation. Cancelling the task that consumes a stream cancels the underlying HTTP request. Call options do not carry an abort signal.
- Upstream `PromiseLike<T>` maps to `async` functions.
- Upstream `unknown` JSON payloads map to `JSONValue`. Upstream `unknown` errors map to `any Error`.
- Upstream `Date` stays `Date`; binary data (`Uint8Array`) maps to `Data`.

## Consequences

Callers get cancellation for free by cancelling their task, including from SwiftUI's `.task` modifier. There is one cancellation mechanism instead of two.
