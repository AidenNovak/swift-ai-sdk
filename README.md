# swift-ai-sdk

A native Swift port of the [Vercel AI SDK](https://github.com/vercel/ai), built for macOS apps first.

- **Native**: compiles into your app. No JavaScript runtime, no sidecar process.
- **Zero third-party dependencies**: only Foundation and URLSession.
- **Provider-agnostic**: one API for DeepSeek, OpenAI, Anthropic and any OpenAI-compatible endpoint.
- **Swift 6 concurrency**: `Sendable` everywhere, streaming via `AsyncThrowingStream`, cancellation via structured `Task` cancellation.

> Status: early development. APIs will change until `1.0`.

## Modules

| Module | Upstream package | Purpose |
| --- | --- | --- |
| `AISDKProvider` | `@ai-sdk/provider` | The provider specification every model implements |
| `AISDKProviderUtils` | `@ai-sdk/provider-utils` | HTTP transport, server-sent events, JSON parsing, schemas, retries, `Tool` and `ModelMessage` types |
| `AISDK` | `ai` | `generateText`, `streamText`, structured output (`Output`, `generateObject`, `streamObject`), `ToolLoopAgent`, tools, multi-step tool loops, tool approval, messages, `embed`/`embedMany`, middleware (`wrapLanguageModel`, `extractReasoningMiddleware`, …), provider registry |
| `AISDKDeepSeek` | `@ai-sdk/deepseek` | DeepSeek chat models (thinking, reasoning effort, tools, JSON output, prefix completion, logprobs) |
| `AISDKAnthropic` | `@ai-sdk/anthropic` | Claude Messages API (thinking, effort, tools, cache control, PDFs, JSON output); also Anthropic-compatible endpoints such as DeepSeek |
| `AISDKOpenAICompatible` | `@ai-sdk/openai-compatible` | Any OpenAI-format API (vLLM, Ollama, LM Studio, OpenRouter, Groq, …): chat, completions, embeddings, pass-through provider options |
| `AISDKOpenAI` | `@ai-sdk/openai` | OpenAI Responses API (default; built-in tools: web search, file search, code interpreter, image generation, MCP, shell, apply patch, computer, tool search, custom tools), Chat Completions, completions, embeddings |
| `AISDKTestUtils` | `@ai-sdk/test-server`, `ai/test` | Replaying HTTP client, mock language model, stream helpers |

## Quick start

```swift
import AISDK
import AISDKDeepSeek

let deepseek = createDeepSeek(DeepSeekProviderSettings(apiKey: "sk-..."))

struct City: Codable, Sendable { var city: String }

let result = try await generateText(
  model: deepseek("deepseek-v4-flash"),
  prompt: "What's the weather in Beijing?",
  tools: [
    "weather": tool(
      description: "Get the weather for a city",
      inputSchema: Schema(City.self, jsonSchema: [
        "type": "object",
        "properties": ["city": ["type": "string"]],
        "required": ["city"],
      ])
    ) { input, _ in ["city": .string(input.city), "celsius": 25] as JSONValue }
  ],
  stopWhen: [.isStepCount(5)]
)
print(result.text)
```

More modules land through pull requests; see [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Requirements

- Swift 6.0+
- macOS 14+ / iOS 17+ (Linux is supported for every module that does not use Apple UI frameworks)

## Installation

```swift
.package(url: "https://github.com/AidenNovak/swift-ai-sdk.git", branch: "main")
```

## DeepSeek

`AISDKDeepSeek` covers every official DeepSeek API, verified against the live service:

| API | Usage |
| --- | --- |
| Chat completions | `deepseek("deepseek-flash")` / `deepseek.chat(...)`: thinking mode, `reasoning` / `reasoningEffort` (`none`/`low`/`high`/`max`), tools, JSON mode, images (inline, URL, uploaded files), logprobs, context-cache usage |
| Chat prefix completion, strict tools (beta) | `createDeepSeek(DeepSeekProviderSettings(baseURL: "https://api.deepseek.com/beta"))` |
| FIM completion (beta) | `deepseek.completion("deepseek-flash")` with `providerOptions: ["deepseek": ["suffix": ...]]` |
| Responses API | `deepseek.responses("deepseek-flash")`: reasoning, tools, `json_schema` structured output, images |
| Files API | `deepseek.files().upload(...)`, `.list()`, `.retrieve(_:)`, `.delete(_:)`; use `FileData.reference(file.reference)` in prompts |
| Models, balance | `deepseek.listModels()`, `deepseek.balance()` |
| Anthropic-compatible API | `createAnthropic(AnthropicProviderSettings(baseURL: "https://api.deepseek.com/anthropic/v1", apiKey: key))` |

When a request carries tools, DeepSeek requires the `reasoning_content` of earlier turns to be sent back; the SDK does this automatically when you append `result.responseMessages` to the conversation.

## 中文说明

swift-ai-sdk 是 Vercel AI SDK 的 Swift 原生移植版，优先服务 macOS 原生应用：直接编译进应用、不依赖任何第三方库、不需要 JavaScript 运行时。设计决策记录在 [`docs/adr`](docs/adr) 目录，开发流程见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。

## License

Apache License 2.0. This project is a derivative work of the Vercel AI SDK (Copyright 2023 Vercel, Inc.); see [`NOTICE`](NOTICE).
