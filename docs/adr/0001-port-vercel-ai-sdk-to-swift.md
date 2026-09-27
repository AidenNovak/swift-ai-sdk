# 0001. Port the Vercel AI SDK to Swift

- Status: accepted
- Date: 2026-09-27

## Context

We need an agent SDK for native macOS apps that we fully control. Running a TypeScript SDK inside a Mac app requires either an embedded JavaScript runtime or a sidecar process, which adds tens of megabytes and a second language to debug. The Vercel AI SDK has the API shape we want: a small provider specification, provider packages, core functions such as `generateText` and `streamText`, and an agent built on top of them.

## Decision

Port the Vercel AI SDK to Swift as a native package with no third-party dependencies.

- Follow the upstream architecture and names so upstream documentation and tests remain a usable specification.
- Pin an upstream commit (see `docs/UPSTREAM.md`) and sync deliberately rather than continuously.
- License the port under Apache 2.0 and keep Vercel's attribution in `NOTICE`, as required for a derivative work.
- Diverge from upstream only where Swift idioms demand it (concurrency, schemas, streams) or where upstream is web-specific.

## Consequences

- We own the roadmap and the stability policy. We can hold the provider specification stable even when upstream breaks it.
- We carry the cost of syncing upstream changes by hand.
- Web-specific upstream features (React Server Components, framework bindings, the Vercel AI Gateway) are out of scope.
