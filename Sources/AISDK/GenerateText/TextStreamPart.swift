import Foundation

/// The start of a streamed tool input. Mirrors upstream `TextStreamToolInputStartPart`.
public struct ToolInputStart: Sendable, Equatable {
  public var id: String
  public var toolName: String
  public var providerMetadata: ProviderMetadata?
  public var toolMetadata: JSONObject?
  public var providerExecuted: Bool?
  public var dynamic: Bool?
  public var title: String?

  public init(
    id: String, toolName: String, providerMetadata: ProviderMetadata? = nil, toolMetadata: JSONObject? = nil,
    providerExecuted: Bool? = nil, dynamic: Bool? = nil, title: String? = nil
  ) {
    self.id = id
    self.toolName = toolName
    self.providerMetadata = providerMetadata
    self.toolMetadata = toolMetadata
    self.providerExecuted = providerExecuted
    self.dynamic = dynamic
    self.title = title
  }
}

/// A part of the `streamText` full stream. Mirrors upstream `TextStreamPart`.
public enum TextStreamPart: Sendable {
  /// The stream started.
  case start
  /// A step started.
  case startStep(request: LanguageModelRequestMetadata, warnings: [Warning])
  case textStart(id: String, providerMetadata: ProviderMetadata? = nil)
  case textDelta(id: String, text: String, providerMetadata: ProviderMetadata? = nil)
  case textEnd(id: String, providerMetadata: ProviderMetadata? = nil)
  case reasoningStart(id: String, providerMetadata: ProviderMetadata? = nil)
  case reasoningDelta(id: String, text: String, providerMetadata: ProviderMetadata? = nil)
  case reasoningEnd(id: String, providerMetadata: ProviderMetadata? = nil)
  case custom(kind: String, providerMetadata: ProviderMetadata? = nil)
  case toolInputStart(ToolInputStart)
  case toolInputDelta(id: String, delta: String, providerMetadata: ProviderMetadata? = nil)
  case toolInputEnd(id: String, providerMetadata: ProviderMetadata? = nil)
  case source(Source)
  case file(GeneratedFile, providerMetadata: ProviderMetadata? = nil)
  case reasoningFile(GeneratedFile, providerMetadata: ProviderMetadata? = nil)
  case toolCall(ToolCall)
  /// A tool result. Preliminary results have `preliminary == true`.
  case toolResult(ToolResult)
  case toolError(ToolError)
  /// Tool execution was denied by the approval configuration.
  case toolOutputDenied(toolCallId: String, toolName: String)
  case toolApprovalRequest(ToolApprovalRequestOutput)
  case toolApprovalResponse(ToolApprovalResponseOutput)
  /// A step finished.
  case finishStep(
    response: LanguageModelResponseMetadata, usage: LanguageModelUsage, finishReason: FinishReason,
    rawFinishReason: String?, providerMetadata: ProviderMetadata?)
  /// The stream finished.
  case finish(finishReason: FinishReason, rawFinishReason: String?, totalUsage: LanguageModelUsage)
  /// The stream was cancelled.
  case abort(reason: String?)
  case error(any Error)
  /// A raw provider chunk, when `includeRawChunks` is enabled.
  case raw(JSONValue)
}

extension TextStreamPart {
  /// The upstream `type` discriminator, handy for logging and tests.
  public var type: String {
    switch self {
    case .start: "start"
    case .startStep: "start-step"
    case .textStart: "text-start"
    case .textDelta: "text-delta"
    case .textEnd: "text-end"
    case .reasoningStart: "reasoning-start"
    case .reasoningDelta: "reasoning-delta"
    case .reasoningEnd: "reasoning-end"
    case .custom: "custom"
    case .toolInputStart: "tool-input-start"
    case .toolInputDelta: "tool-input-delta"
    case .toolInputEnd: "tool-input-end"
    case .source: "source"
    case .file: "file"
    case .reasoningFile: "reasoning-file"
    case .toolCall: "tool-call"
    case .toolResult: "tool-result"
    case .toolError: "tool-error"
    case .toolOutputDenied: "tool-output-denied"
    case .toolApprovalRequest: "tool-approval-request"
    case .toolApprovalResponse: "tool-approval-response"
    case .finishStep: "finish-step"
    case .finish: "finish"
    case .abort: "abort"
    case .error: "error"
    case .raw: "raw"
    }
  }

  /// Whether the part is passed to `onChunk`. Mirrors upstream `isContentChunk`.
  var isChunk: Bool {
    switch self {
    case .textDelta(_, let text, _), .reasoningDelta(_, let text, _): !text.isEmpty
    case .toolInputDelta(_, let delta, _): !delta.isEmpty
    case .source, .toolCall, .toolInputStart, .toolResult, .raw, .file, .reasoningFile, .custom: true
    default: false
    }
  }
}

/// Transforms the full stream, e.g. `smoothStream()`. Mirrors upstream `StreamTextTransform`.
public typealias StreamTextTransform =
  @Sendable (AsyncThrowingStream<TextStreamPart, any Error>) -> AsyncThrowingStream<TextStreamPart, any Error>

/// How `smoothStream` splits text.
public enum ChunkingStrategy: Sendable {
  /// Emits one word (plus trailing whitespace) at a time.
  case word
  /// Emits one line at a time.
  case line
  /// Emits text up to and including each match of the regular expression.
  case regex(String)
}

/// Smooths text and reasoning streaming by re-chunking deltas and pausing
/// between chunks. Mirrors upstream `smoothStream`.
public func smoothStream(delayInMs: Double? = 10, chunking: ChunkingStrategy = .word) -> StreamTextTransform {
  let pattern: String =
    switch chunking {
    case .word: #"\S+\s+"#
    case .line: #"\n+"#
    case .regex(let pattern): pattern
    }

  return { input in
    AsyncThrowingStream { continuation in
      let task = Task {
        let regex = try? NSRegularExpression(pattern: pattern)
        var buffer = ""
        var bufferId = ""
        var bufferIsReasoning = false
        var bufferMetadata: ProviderMetadata?

        func emit(_ text: String) {
          continuation.yield(
            bufferIsReasoning
              ? .reasoningDelta(id: bufferId, text: text, providerMetadata: bufferMetadata)
              : .textDelta(id: bufferId, text: text, providerMetadata: bufferMetadata))
        }

        func flush() {
          if !buffer.isEmpty { emit(buffer) }
          buffer = ""
        }

        do {
          for try await part in input {
            let delta: (id: String, text: String, isReasoning: Bool, metadata: ProviderMetadata?)? =
              switch part {
              case .textDelta(let id, let text, let metadata): (id, text, false, metadata)
              case .reasoningDelta(let id, let text, let metadata): (id, text, true, metadata)
              default: nil
              }

            guard let delta else {
              flush()
              continuation.yield(part)
              continue
            }

            if (delta.id != bufferId || delta.isReasoning != bufferIsReasoning) && !buffer.isEmpty {
              flush()
            }
            bufferId = delta.id
            bufferIsReasoning = delta.isReasoning
            bufferMetadata = delta.metadata ?? bufferMetadata
            buffer += delta.text

            while let regex,
              let match = regex.firstMatch(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)),
              let range = Range(match.range, in: buffer), !range.isEmpty
            {
              let chunk = String(buffer[..<range.upperBound])
              buffer = String(buffer[range.upperBound...])
              emit(chunk)
              try await delay(delayInMs)
            }
          }
          flush()
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }
}
