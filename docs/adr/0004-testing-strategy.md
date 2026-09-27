# 0004. Testing strategy

- Status: accepted
- Date: 2026-09-27

## Decision

- Tests use Swift Testing (`import Testing`).
- Upstream tests are the behavioral specification. When porting a file, port its tests.
- Provider tests never hit the network. They run against recorded HTTP responses (JSON bodies and server-sent event streams) through a replaying `HTTPClient`.
- Core tests run against `MockLanguageModelV4`, so the tool loop, stop conditions and stream transformations are tested deterministically.
- Live tests against real APIs are opt-in through environment variables and never run in CI.

## Consequences

The recorded fixtures double as a conformance suite for any future implementation in another language.
