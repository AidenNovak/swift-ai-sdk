# Roadmap

Each item lands as one or more pull requests.

| Module | Upstream | Scope |
| --- | --- | --- |
| `AISDKProvider` | `@ai-sdk/provider` | JSON values, `LanguageModelV4`, prompt and stream part types, usage, warnings, errors, `EmbeddingModelV4`, `ProviderV4` |
| `AISDKProviderUtils` | `@ai-sdk/provider-utils` | `HTTPClient` + URLSession transport, server-sent events, `postJsonToApi`, response handlers, `loadApiKey`, `generateId`, `Schema<T>` |
| `AISDK` | `ai` | `generateText`, `streamText`, tools and multi-step tool loops, `stopWhen`, retries, structured output, `ToolLoopAgent`, `embed`/`embedMany`, middleware, provider registry |
| `AISDKTestUtils` | `ai/test`, `@ai-sdk/test-server` | Mock models, recorded-response replay |
| `AISDKOpenAICompatible` | `@ai-sdk/openai-compatible` | Chat completions and embeddings for OpenAI-compatible endpoints |
| `AISDKDeepSeek` | `@ai-sdk/deepseek` | DeepSeek official API in both OpenAI and Anthropic formats |
| `AISDKOpenAI` | `@ai-sdk/openai` | Chat completions, Responses API, embeddings |
| `AISDKAnthropic` | `@ai-sdk/anthropic` | Messages API |
| `AISDKMCP` | `@ai-sdk/mcp` | MCP client over stdio and streamable HTTP |
| `AISDKUI` | `@ai-sdk/react` | UI message stream protocol and a SwiftUI chat model (the `useChat` equivalent) |

Not planned for now: App Store sandbox specifics, the Vercel AI Gateway, harness packages, and web framework bindings.
