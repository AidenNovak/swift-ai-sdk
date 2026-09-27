# Contributing

## Workflow

- `main` is protected. Every change lands through a pull request; direct pushes are rejected.
- A pull request needs green CI (`macOS` and `Linux` jobs) before it can merge. We squash-merge.
- Keep one topic per pull request. A port of one upstream package, or one feature, is a good size.

## Porting rules

1. **Track upstream.** Each ported file mirrors an upstream file in `vercel/ai`. The upstream commit we port from is recorded in `AISDKProviderInfo.upstreamCommit` and [`docs/UPSTREAM.md`](docs/UPSTREAM.md).
2. **Keep names recognizable.** Types and functions keep their upstream names in Swift casing (`generateText`, `LanguageModelV4StreamPart`), so upstream docs stay useful.
3. **Translate idioms, not syntax.**
   - `AbortSignal` becomes structured `Task` cancellation.
   - `ReadableStream<T>` becomes `AsyncThrowingStream<T, any Error>`.
   - `unknown` JSON payloads become `JSONValue`.
   - zod / Standard Schema becomes `Schema<T>` built from a JSON Schema plus `Decodable`.
4. **Port the tests too.** Upstream behavior is the specification. Port the relevant upstream tests along with the code.

## Architecture constraints

These are enforced in review and, where possible, in CI:

- `AISDKProvider` depends on Foundation only.
- No module except `AISDKUI` may import SwiftUI, AppKit or UIKit.
- HTTP goes through the `HTTPClient` protocol; nothing else calls `URLSession` directly.
- Every public type is `Sendable`.
- No third-party dependencies.

## Local checks

```sh
swift build
swift test
```

## Live tests

`Tests/AISDKLiveTests` calls real APIs. They are skipped unless explicitly enabled, never run in CI, and cost a few cents per run:

```sh
AISDK_LIVE_TESTS=1 DEEPSEEK_API_KEY=sk-... swift test --filter AISDKLiveTests
```

Never commit API keys. Fixtures recorded from live APIs must not contain credentials or account data.

## Upstream conformance cases

Some tests replay cases recorded by running the upstream TypeScript code itself on the same fixtures, then compare request bodies, content, stream parts, usage and warnings with the Swift port (for example `Tests/AISDKOpenAITests/Fixtures/openai-responses-conformance.json`). To regenerate them after bumping the upstream commit:

```sh
Tools/conformance/run.sh /path/to/vercel-ai                     # every script
Tools/conformance/run.sh /path/to/vercel-ai ui-message-stream   # one script
```

The script installs a few npm packages into a temporary directory and removes them afterwards. `anthropic-messages.mts` replays upstream's recorded Anthropic API responses (copied to `Tests/AISDKAnthropicTests/Fixtures/upstream`) plus request-only cases for options and prompt conversion. `ui-message-stream.mts` covers the UI message stream processing, `toUIMessageStream` over `streamText`, `convertToModelMessages`, `validateUIMessages`, `createUIMessageStream` and the chat state machine (`Tests/AISDKUITests/Fixtures/ui-conformance.json`).
