# 0002. Module boundaries and dependency direction

- Status: accepted
- Date: 2026-09-27

## Decision

Modules mirror upstream packages. Dependencies only point inward:

```text
AISDKUI ──► AISDK ──► AISDKProviderUtils ──► AISDKProvider
Providers (AISDKDeepSeek, AISDKOpenAI, ...) ──► AISDKProviderUtils ──► AISDKProvider
```

- `AISDKProvider` is the contract. It depends on Foundation only and changes rarely. Adding a case to a public enum in it is a breaking change and needs an ADR.
- Provider modules never depend on `AISDK`. A provider only knows the specification.
- `AISDK` never depends on a concrete provider.
- Only `AISDKUI` may import SwiftUI, AppKit or UIKit. Everything else must build on Linux, which CI verifies.
- All HTTP goes through the `HTTPClient` protocol in `AISDKProviderUtils`, so apps can inject their own transport and tests can replay recorded responses.

## Consequences

The Linux CI job fails as soon as a non-UI module reaches for an Apple-only API, which keeps the core portable to a future server-side use.
