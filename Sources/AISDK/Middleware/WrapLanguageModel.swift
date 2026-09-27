import Foundation

/// Language model middleware. Mirrors upstream `LanguageModelMiddleware`.
public typealias LanguageModelMiddleware = LanguageModelV4Middleware

/// Embedding model middleware. Mirrors upstream `EmbeddingModelMiddleware`.
public typealias EmbeddingModelMiddleware = EmbeddingModelV4Middleware

/// Wraps a language model with middleware. The first middleware is the
/// outermost. Mirrors upstream `wrapLanguageModel`.
public func wrapLanguageModel(
  model: any LanguageModelV4,
  middleware: [LanguageModelMiddleware],
  modelId: String? = nil,
  providerId: String? = nil
) -> any LanguageModelV4 {
  middleware.reversed().reduce(model) { wrapped, middleware in
    WrappedLanguageModel(model: wrapped, middleware: middleware, modelIdOverride: modelId, providerIdOverride: providerId)
  }
}

/// Wraps a language model with one middleware.
public func wrapLanguageModel(
  model: any LanguageModelV4, middleware: LanguageModelMiddleware, modelId: String? = nil, providerId: String? = nil
) -> any LanguageModelV4 {
  wrapLanguageModel(model: model, middleware: [middleware], modelId: modelId, providerId: providerId)
}

private struct WrappedLanguageModel: LanguageModelV4 {
  let model: any LanguageModelV4
  let middleware: LanguageModelMiddleware
  let modelIdOverride: String?
  let providerIdOverride: String?

  var provider: String { providerIdOverride ?? middleware.overrideProvider?(model) ?? model.provider }
  var modelId: String { modelIdOverride ?? middleware.overrideModelId?(model) ?? model.modelId }

  var supportedUrls: [String: [String]] {
    get async throws {
      if let override = middleware.overrideSupportedUrls { return try await override(model) }
      return try await model.supportedUrls
    }
  }

  private func options(_ params: LanguageModelV4CallOptions, type: LanguageModelV4CallType) async throws
    -> LanguageModelV4WrapOptions
  {
    let transformed =
      if let transformParams = middleware.transformParams { try await transformParams(type, params, model) } else { params }
    let model = model
    return LanguageModelV4WrapOptions(
      doGenerate: { try await model.doGenerate(transformed) },
      doStream: { try await model.doStream(transformed) },
      params: transformed, model: model)
  }

  func doGenerate(_ params: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let wrapOptions = try await options(params, type: .generate)
    if let wrapGenerate = middleware.wrapGenerate { return try await wrapGenerate(wrapOptions) }
    return try await wrapOptions.doGenerate()
  }

  func doStream(_ params: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let wrapOptions = try await options(params, type: .stream)
    if let wrapStream = middleware.wrapStream { return try await wrapStream(wrapOptions) }
    return try await wrapOptions.doStream()
  }
}

/// Wraps an embedding model with middleware. Mirrors upstream `wrapEmbeddingModel`.
public func wrapEmbeddingModel(
  model: any EmbeddingModelV4,
  middleware: [EmbeddingModelMiddleware],
  modelId: String? = nil,
  providerId: String? = nil
) -> any EmbeddingModelV4 {
  middleware.reversed().reduce(model) { wrapped, middleware in
    WrappedEmbeddingModel(model: wrapped, middleware: middleware, modelIdOverride: modelId, providerIdOverride: providerId)
  }
}

private struct WrappedEmbeddingModel: EmbeddingModelV4 {
  let model: any EmbeddingModelV4
  let middleware: EmbeddingModelMiddleware
  let modelIdOverride: String?
  let providerIdOverride: String?

  var provider: String { providerIdOverride ?? middleware.overrideProvider?(model) ?? model.provider }
  var modelId: String { modelIdOverride ?? middleware.overrideModelId?(model) ?? model.modelId }
  var maxEmbeddingsPerCall: Int? { get async throws { try await model.maxEmbeddingsPerCall } }
  var supportsParallelCalls: Bool { get async throws { try await model.supportsParallelCalls } }

  func doEmbed(_ params: EmbeddingModelV4CallOptions) async throws -> EmbeddingModelV4Result {
    let transformed =
      if let transformParams = middleware.transformParams { try await transformParams(params, model) } else { params }
    let model = model
    let doEmbed: @Sendable () async throws -> EmbeddingModelV4Result = { try await model.doEmbed(transformed) }
    if let wrapEmbed = middleware.wrapEmbed {
      return try await wrapEmbed(EmbeddingModelV4WrapOptions(doEmbed: doEmbed, params: transformed, model: model))
    }
    return try await doEmbed()
  }
}

/// Wraps every language model of a provider with middleware. Mirrors upstream `wrapProvider`.
public func wrapProvider(provider: any ProviderV4, languageModelMiddleware: [LanguageModelMiddleware]) -> any ProviderV4 {
  WrappedProvider(provider: provider, middleware: languageModelMiddleware)
}

private struct WrappedProvider: ProviderV4 {
  let provider: any ProviderV4
  let middleware: [LanguageModelMiddleware]

  func languageModel(_ modelId: String) throws -> any LanguageModelV4 {
    wrapLanguageModel(model: try provider.languageModel(modelId), middleware: middleware)
  }

  func embeddingModel(_ modelId: String) throws -> any EmbeddingModelV4 {
    try provider.embeddingModel(modelId)
  }
}

// MARK: - Built-in middleware

/// Default call settings, overridden by per-call settings. Mirrors upstream
/// `defaultSettingsMiddleware`.
public func defaultSettingsMiddleware(
  maxOutputTokens: Int? = nil,
  temperature: Double? = nil,
  stopSequences: [String]? = nil,
  topP: Double? = nil,
  topK: Int? = nil,
  presencePenalty: Double? = nil,
  frequencyPenalty: Double? = nil,
  responseFormat: LanguageModelV4ResponseFormat? = nil,
  seed: Int? = nil,
  tools: [LanguageModelV4Tool]? = nil,
  toolChoice: LanguageModelV4ToolChoice? = nil,
  headers: [String: String]? = nil,
  reasoning: LanguageModelV4ReasoningEffort? = nil,
  providerOptions: SharedV4ProviderOptions? = nil
) -> LanguageModelMiddleware {
  LanguageModelMiddleware(transformParams: { _, params, _ in
    var merged = params
    merged.maxOutputTokens = params.maxOutputTokens ?? maxOutputTokens
    merged.temperature = params.temperature ?? temperature
    merged.stopSequences = params.stopSequences ?? stopSequences
    merged.topP = params.topP ?? topP
    merged.topK = params.topK ?? topK
    merged.presencePenalty = params.presencePenalty ?? presencePenalty
    merged.frequencyPenalty = params.frequencyPenalty ?? frequencyPenalty
    merged.responseFormat = params.responseFormat ?? responseFormat
    merged.seed = params.seed ?? seed
    merged.tools = params.tools ?? tools
    merged.toolChoice = params.toolChoice ?? toolChoice
    merged.reasoning = params.reasoning ?? reasoning
    if let headers {
      merged.headers = headers.merging(params.headers ?? [:]) { _, call in call }
    }
    merged.providerOptions = mergeProviderOptions(providerOptions, params.providerOptions)
    return merged
  })
}

/// Default embedding settings. Mirrors upstream `defaultEmbeddingSettingsMiddleware`.
public func defaultEmbeddingSettingsMiddleware(
  headers: [String: String]? = nil, providerOptions: SharedV4ProviderOptions? = nil
) -> EmbeddingModelMiddleware {
  EmbeddingModelMiddleware(transformParams: { params, _ in
    var merged = params
    if let headers {
      merged.headers = headers.merging(params.headers ?? [:]) { _, call in call }
    }
    merged.providerOptions = mergeProviderOptions(providerOptions, params.providerOptions)
    return merged
  })
}

/// Turns `doStream` into a single `doGenerate` call replayed as a stream.
/// Mirrors upstream `simulateStreamingMiddleware`.
public func simulateStreamingMiddleware() -> LanguageModelMiddleware {
  LanguageModelMiddleware(wrapStream: { options in
    let result = try await options.doGenerate()
    var parts: [LanguageModelV4StreamPart] = [.streamStart(warnings: result.warnings)]
    if let metadata = result.response?.metadata { parts.append(.responseMetadata(metadata)) }
    var id = 0
    for content in result.content {
      switch content {
      case .text(let text):
        guard !text.text.isEmpty else { continue }
        parts += [
          .textStart(id: String(id), providerMetadata: text.providerMetadata),
          .textDelta(id: String(id), delta: text.text), .textEnd(id: String(id)),
        ]
        id += 1
      case .reasoning(let reasoning):
        parts += [
          .reasoningStart(id: String(id), providerMetadata: reasoning.providerMetadata),
          .reasoningDelta(id: String(id), delta: reasoning.text), .reasoningEnd(id: String(id)),
        ]
        id += 1
      case .custom(let custom): parts.append(.custom(custom))
      case .reasoningFile(let file): parts.append(.reasoningFile(file))
      case .file(let file): parts.append(.file(file))
      case .toolApprovalRequest(let request): parts.append(.toolApprovalRequest(request))
      case .source(let source): parts.append(.source(source))
      case .toolCall(let call): parts.append(.toolCall(call))
      case .toolResult(let toolResult): parts.append(.toolResult(toolResult))
      }
    }
    parts.append(.finish(usage: result.usage, finishReason: result.finishReason, providerMetadata: result.providerMetadata))
    let finalParts = parts
    return LanguageModelV4StreamResult(
      stream: LanguageModelV4Stream { continuation in
        for part in finalParts { continuation.yield(part) }
        continuation.finish()
      },
      request: result.request, responseHeaders: result.response?.headers)
  })
}

/// Returns the index where `searched` starts in `text`, or where a suffix of
/// `text` starts a prefix of `searched`. Mirrors upstream `getPotentialStartIndex`.
func getPotentialStartIndex(_ text: String, _ searched: String) -> String.Index? {
  guard !searched.isEmpty else { return nil }
  if let range = text.range(of: searched) { return range.lowerBound }
  var index = text.endIndex
  while index > text.startIndex {
    index = text.index(before: index)
    if searched.hasPrefix(text[index...]) { return index }
  }
  return nil
}

/// Extracts `<tag>...</tag>` sections from text into reasoning. Mirrors
/// upstream `extractReasoningMiddleware`.
public func extractReasoningMiddleware(tagName: String, separator: String = "\n", startWithReasoning: Bool = false)
  -> LanguageModelMiddleware
{
  let openingTag = "<\(tagName)>"
  let closingTag = "</\(tagName)>"

  return LanguageModelMiddleware(
    wrapGenerate: { options in
      var result = try await options.doGenerate()
      var content: [LanguageModelV4Content] = []
      for part in result.content {
        guard case .text(let textPart) = part else {
          content.append(part)
          continue
        }
        let text = startWithReasoning ? openingTag + textPart.text : textPart.text
        var reasoning: [String] = []
        var remaining = ""
        var cursor = text.startIndex
        while let open = text.range(of: openingTag, range: cursor..<text.endIndex),
          let close = text.range(of: closingTag, range: open.upperBound..<text.endIndex)
        {
          let before = String(text[cursor..<open.lowerBound])
          if !before.isEmpty {
            if !remaining.isEmpty { remaining += separator }
            remaining += before
          }
          reasoning.append(String(text[open.upperBound..<close.lowerBound]))
          cursor = close.upperBound
        }
        guard !reasoning.isEmpty else {
          content.append(part)
          continue
        }
        let after = String(text[cursor...])
        if !after.isEmpty {
          if !remaining.isEmpty { remaining += separator }
          remaining += after
        }
        content.append(.reasoning(LanguageModelV4Reasoning(text: reasoning.joined(separator: separator))))
        content.append(.text(LanguageModelV4Text(text: remaining)))
      }
      result.content = content
      return result
    },
    wrapStream: { options in
      let result = try await options.doStream()
      let source = result.stream
      let stream = LanguageModelV4Stream { continuation in
        let task = Task {
          let extractor = ReasoningExtractor(
            openingTag: openingTag, closingTag: closingTag, separator: separator,
            startWithReasoning: startWithReasoning)
          do {
            for try await part in source {
              extractor.process(part) { continuation.yield($0) }
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
      }
      return LanguageModelV4StreamResult(stream: stream, request: result.request, responseHeaders: result.responseHeaders)
    })
}

private final class ReasoningExtractor {
  struct Extraction {
    var isFirstReasoning = true
    var isFirstText = true
    var afterSwitch = false
    var isReasoning: Bool
    var buffer = ""
    var reasoningId: String?
  }

  let openingTag: String
  let closingTag: String
  let separator: String
  let startWithReasoning: Bool
  var extractions: [String: Extraction] = [:]
  var delayedTextStarts: [String: LanguageModelV4StreamPart] = [:]
  var reasoningCounter = 0

  init(openingTag: String, closingTag: String, separator: String, startWithReasoning: Bool) {
    self.openingTag = openingTag
    self.closingTag = closingTag
    self.separator = separator
    self.startWithReasoning = startWithReasoning
  }

  func process(_ part: LanguageModelV4StreamPart, emit: (LanguageModelV4StreamPart) -> Void) {
    if case .textStart(let id, _) = part {
      delayedTextStarts[id] = part
      return
    }
    if case .textEnd(let id, _) = part, let start = delayedTextStarts.removeValue(forKey: id) {
      emit(start)
    }
    guard case .textDelta(let id, let delta, _) = part else {
      emit(part)
      return
    }

    var extraction = extractions[id] ?? Extraction(isReasoning: startWithReasoning)
    extraction.buffer += delta

    func reasoningId() -> String {
      if let existing = extraction.reasoningId { return existing }
      let newId = "reasoning-\(reasoningCounter)"
      reasoningCounter += 1
      extraction.reasoningId = newId
      return newId
    }

    func publish(_ text: String) {
      guard !text.isEmpty else { return }
      let needsSeparator =
        extraction.afterSwitch && (extraction.isReasoning ? !extraction.isFirstReasoning : !extraction.isFirstText)
      let prefix = needsSeparator ? separator : ""
      if extraction.isReasoning {
        if extraction.afterSwitch || extraction.isFirstReasoning { emit(.reasoningStart(id: reasoningId())) }
        emit(.reasoningDelta(id: reasoningId(), delta: prefix + text))
        extraction.isFirstReasoning = false
      } else {
        if let start = delayedTextStarts.removeValue(forKey: id) { emit(start) }
        emit(.textDelta(id: id, delta: prefix + text))
        extraction.isFirstText = false
      }
      extraction.afterSwitch = false
    }

    while true {
      let nextTag = extraction.isReasoning ? closingTag : openingTag
      guard let start = getPotentialStartIndex(extraction.buffer, nextTag) else {
        publish(extraction.buffer)
        extraction.buffer = ""
        break
      }
      publish(String(extraction.buffer[..<start]))
      let tagEnd = extraction.buffer.index(start, offsetBy: nextTag.count, limitedBy: extraction.buffer.endIndex)
      guard let tagEnd, extraction.buffer[start..<tagEnd] == nextTag else {
        extraction.buffer = String(extraction.buffer[start...])
        break
      }
      extraction.buffer = String(extraction.buffer[tagEnd...])
      if extraction.isReasoning {
        if extraction.isFirstReasoning { emit(.reasoningStart(id: reasoningId())) }
        emit(.reasoningEnd(id: reasoningId()))
        extraction.reasoningId = nil
      }
      extraction.isReasoning.toggle()
      extraction.afterSwitch = true
    }
    extractions[id] = extraction
  }
}

/// Strips markdown code fences around JSON text. Mirrors upstream
/// `extractJsonMiddleware` for generate calls; streamed text is buffered per
/// block and transformed when the block ends.
public func extractJsonMiddleware(transform: (@Sendable (String) -> String)? = nil) -> LanguageModelMiddleware {
  let transform = transform ?? { text in
    var result = text
    if let range = result.range(of: #"^```(?:json)?\s*\n?"#, options: .regularExpression) {
      result.removeSubrange(range)
    }
    if let range = result.range(of: #"\n?```\s*$"#, options: .regularExpression) {
      result.removeSubrange(range)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  return LanguageModelMiddleware(
    wrapGenerate: { options in
      var result = try await options.doGenerate()
      result.content = result.content.map { part in
        guard case .text(var text) = part else { return part }
        text.text = transform(text.text)
        return .text(text)
      }
      return result
    },
    wrapStream: { options in
      let result = try await options.doStream()
      let source = result.stream
      let stream = LanguageModelV4Stream { continuation in
        let task = Task {
          var buffers: [String: String] = [:]
          do {
            for try await part in source {
              switch part {
              case .textStart(let id, _):
                buffers[id] = ""
                continuation.yield(part)
              case .textDelta(let id, let delta, _) where buffers[id] != nil:
                buffers[id]! += delta
              case .textEnd(let id, _):
                if let text = buffers.removeValue(forKey: id) {
                  let transformed = transform(text)
                  if !transformed.isEmpty { continuation.yield(.textDelta(id: id, delta: transformed)) }
                }
                continuation.yield(part)
              default:
                continuation.yield(part)
              }
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
      }
      return LanguageModelV4StreamResult(stream: stream, request: result.request, responseHeaders: result.responseHeaders)
    })
}
