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
| `AISDKProviderUtils` | `@ai-sdk/provider-utils` | HTTP transport, server-sent events, JSON parsing, schemas, retries |
| `AISDK` | `ai` | `generateText`, `streamText`, tools, multi-step tool loops, tool approval, messages |
| `AISDKDeepSeek` | `@ai-sdk/deepseek` | DeepSeek chat models (thinking, reasoning effort, tools, JSON output, prefix completion, logprobs) |
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

## 中文说明

swift-ai-sdk 是 Vercel AI SDK 的 Swift 原生移植版，优先服务 macOS 原生应用：直接编译进应用、不依赖任何第三方库、不需要 JavaScript 运行时。设计决策记录在 [`docs/adr`](docs/adr) 目录，开发流程见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。

## License

Apache License 2.0. This project is a derivative work of the Vercel AI SDK (Copyright 2023 Vercel, Inc.); see [`NOTICE`](NOTICE).
