import Foundation

/// A URL the SDK may need to download before calling the model.
public struct PlannedDownload: Sendable, Equatable {
  public var url: URL
  /// Whether the model can fetch the URL itself.
  public var isUrlSupportedByModel: Bool
}

/// A downloaded file.
public struct DownloadedFile: Sendable, Equatable {
  public var data: Data
  public var mediaType: String?

  public init(data: Data, mediaType: String?) {
    self.data = data
    self.mediaType = mediaType
  }
}

/// Downloads files referenced by URL. Returns `nil` for URLs that should be
/// passed to the model unchanged. Mirrors upstream `DownloadFunction`.
public typealias DownloadFunction = @Sendable ([PlannedDownload]) async throws -> [DownloadedFile?]

/// Downloads every URL the model does not support natively. Mirrors upstream
/// `createDefaultDownloadFunction`.
public func createDefaultDownloadFunction(httpClient: (any HTTPClient)? = nil) -> DownloadFunction {
  { plannedDownloads in
    try await withThrowingTaskGroup(of: (Int, DownloadedFile?).self) { group in
      for (index, planned) in plannedDownloads.enumerated() {
        group.addTask {
          guard !planned.isUrlSupportedByModel else { return (index, nil) }
          return (index, try await download(url: planned.url, httpClient: httpClient))
        }
      }
      var results = [DownloadedFile?](repeating: nil, count: plannedDownloads.count)
      for try await (index, file) in group {
        results[index] = file
      }
      return results
    }
  }
}

/// Downloads a file from an untrusted URL, rejecting private-network targets
/// on every redirect hop and enforcing a size limit. Mirrors upstream `download`.
public func download(
  url: URL, maxBytes: Int = DEFAULT_MAX_DOWNLOAD_SIZE, httpClient: (any HTTPClient)? = nil
) async throws -> DownloadedFile {
  let urlText = url.absoluteString
  do {
    let response = try await fetchUntrustedUrl(
      url: urlText, headers: withUserAgentSuffix([:], "ai-sdk/\(AISDK_VERSION)", "runtime/swift"),
      httpClient: httpClient)
    guard response.isOK else {
      throw DownloadError(url: urlText, statusCode: response.statusCode, statusText: response.statusText)
    }
    let data = try await readResponseWithSizeLimit(response, url: urlText, maxBytes: maxBytes)
    return DownloadedFile(data: data, mediaType: response.headers["content-type"])
  } catch let error where error is DownloadError || isCancellationError(error) {
    throw error
  } catch {
    throw DownloadError(url: urlText, cause: error)
  }
}

/// Converts a standardized prompt to the specification prompt, downloading
/// unsupported URLs. Mirrors upstream `convertToLanguageModelPrompt`.
///
/// - Throws: `MissingToolResultsError` when tool calls lack results.
public func convertToLanguageModelPrompt(
  prompt: StandardizedPrompt,
  supportedUrls: [String: [String]],
  download: DownloadFunction? = nil
) async throws -> LanguageModelV4Prompt {
  let downloadedAssets = try await downloadAssets(
    messages: prompt.messages, download: download ?? createDefaultDownloadFunction(),
    supportedUrls: supportedUrls)

  var approvalIdToToolCallId: [String: String] = [:]
  for case .assistant(let message) in prompt.messages {
    for case .toolApprovalRequest(let request) in message.content {
      approvalIdToToolCallId[request.approvalId] = request.toolCallId
    }
  }
  var approvedToolCallIds = Set<String>()
  for case .tool(let message) in prompt.messages {
    for case .toolApprovalResponse(let response) in message.content {
      if let toolCallId = approvalIdToToolCallId[response.approvalId] {
        approvedToolCallIds.insert(toolCallId)
      }
    }
  }

  var messages: [LanguageModelV4Message] = []
  switch prompt.instructions {
  case .text(let text):
    messages.append(.system(text))
  case .messages(let systemMessages):
    messages += systemMessages.map { .system($0.content, providerOptions: $0.providerOptions) }
  case nil:
    break
  }
  for message in prompt.messages {
    messages.append(try convertToLanguageModelMessage(message, downloadedAssets: downloadedAssets))
  }

  var combined: [LanguageModelV4Message] = []
  for message in messages {
    guard case .tool(let content, let options) = message,
      case .tool(var lastContent, let lastOptions)? = combined.last
    else {
      combined.append(message)
      continue
    }
    if let lastOptions, !lastContent.isEmpty {
      lastContent[lastContent.count - 1] = lastContent[lastContent.count - 1].mergingProviderOptions(lastOptions)
    }
    combined[combined.count - 1] = .tool(lastContent + content, providerOptions: options)
  }

  var pendingToolCallIds: [String] = []
  func checkPending() throws {
    pendingToolCallIds.removeAll { approvedToolCallIds.contains($0) }
    if !pendingToolCallIds.isEmpty {
      throw MissingToolResultsError(toolCallIds: pendingToolCallIds)
    }
  }
  for message in combined {
    switch message {
    case .assistant(let content, _):
      for case .toolCall(let call) in content where call.providerExecuted != true {
        if !pendingToolCallIds.contains(call.toolCallId) { pendingToolCallIds.append(call.toolCallId) }
      }
    case .tool(let content, _):
      for case .toolResult(let result) in content {
        pendingToolCallIds.removeAll { $0 == result.toolCallId }
      }
    case .user, .system:
      try checkPending()
    }
  }
  try checkPending()

  return combined.filter {
    if case .tool(let content, _) = $0 { return !content.isEmpty }
    return true
  }
}

extension LanguageModelV4ToolContentPart {
  fileprivate func mergingProviderOptions(_ options: SharedV4ProviderOptions) -> Self {
    switch self {
    case .toolResult(var part):
      part.providerOptions = mergeProviderOptions(options, part.providerOptions)
      return .toolResult(part)
    case .toolApprovalResponse(var part):
      part.providerOptions = mergeProviderOptions(options, part.providerOptions)
      return .toolApprovalResponse(part)
    }
  }
}

/// Deep-merges provider options; `overrides` wins. Mirrors upstream `mergeObjects`.
func mergeProviderOptions(_ base: SharedV4ProviderOptions?, _ overrides: SharedV4ProviderOptions?)
  -> SharedV4ProviderOptions?
{
  guard let base else { return overrides }
  guard let overrides else { return base }
  var merged = base
  for (provider, options) in overrides {
    merged[provider] = mergeJSONObjects(merged[provider] ?? [:], options)
  }
  return merged
}

func mergeJSONObjects(_ base: JSONObject, _ overrides: JSONObject) -> JSONObject {
  var merged = base
  for (key, value) in overrides {
    if case .object(let baseObject)? = merged[key], case .object(let overrideObject) = value {
      merged[key] = .object(mergeJSONObjects(baseObject, overrideObject))
    } else {
      merged[key] = value
    }
  }
  return merged
}

typealias DownloadedAssets = [String: DownloadedFile]

private func downloadAssets(
  messages: [ModelMessage], download: DownloadFunction, supportedUrls: [String: [String]]
) async throws -> DownloadedAssets {
  var files: [(data: FileData, mediaType: String?)] = []
  for message in messages {
    switch message {
    case .user(let user):
      for part in user.content {
        switch part {
        case .image(let image): files.append((image.image, image.mediaType ?? "image"))
        case .file(let file): files.append((file.data, file.mediaType))
        case .text: break
        }
      }
    case .tool(let tool):
      for case .toolResult(let result) in tool.content {
        files += contentFiles(result.output)
      }
    case .assistant(let assistant):
      for case .toolResult(let result) in assistant.content {
        files += contentFiles(result.output)
      }
    case .system:
      break
    }
  }

  let planned: [PlannedDownload] = files.compactMap { file in
    guard case .url(let url, _) = normalizeFileData(file.data).data else { return nil }
    let supported =
      file.mediaType.map {
        isUrlSupported(mediaType: $0, url: url.absoluteString, supportedUrls: supportedUrls)
      } ?? false
    return PlannedDownload(url: url, isUrlSupportedByModel: supported)
  }
  guard !planned.isEmpty else { return [:] }

  let downloaded = try await download(planned)
  var assets: DownloadedAssets = [:]
  for (index, file) in downloaded.enumerated() where index < planned.count {
    if let file { assets[planned[index].url.absoluteString] = file }
  }
  return assets
}

private func contentFiles(_ output: ToolResultOutput) -> [(data: FileData, mediaType: String?)] {
  guard case .content(let parts) = output else { return [] }
  return parts.compactMap {
    if case .file(let data, let mediaType, _, _) = $0 { return (data, mediaType) }
    return nil
  }
}

/// Splits `data:` URLs into base64 content and media type.
/// Mirrors upstream `convertToLanguageModelV4FilePart`.
func normalizeFileData(_ data: FileData) -> (data: FileData, mediaType: String?) {
  guard case .url(let url, _) = data, url.scheme == "data" else { return (data, nil) }
  let string = url.absoluteString
  guard let comma = string.firstIndex(of: ",") else { return (data, nil) }
  let header = string[string.index(string.startIndex, offsetBy: 5)..<comma]
  let mediaType = header.split(separator: ";").first.map(String.init)
  let content = String(string[string.index(after: comma)...])
  if header.contains(";base64") {
    return (.base64(content), mediaType)
  }
  return (.data(Data((content.removingPercentEncoding ?? content).utf8)), mediaType)
}

private func convertFilePart(
  data: FileData, mediaType partMediaType: String?, filename: String?, providerOptions: ProviderOptions?,
  downloadedAssets: DownloadedAssets
) throws -> LanguageModelV4FilePart {
  let normalized = normalizeFileData(data)
  var mediaType = normalized.mediaType ?? partMediaType
  var fileData = normalized.data

  if case .url(let url, _) = fileData, let downloaded = downloadedAssets[url.absoluteString] {
    fileData = .data(downloaded.data)
    if let downloadedType = downloaded.mediaType, mediaType == nil || !isFullMediaType(mediaType!) {
      mediaType = downloadedType
    }
  }

  switch fileData {
  case .data(let bytes):
    if let detected = detectMediaType(data: bytes, topLevelType: "image") { mediaType = detected }
  case .base64(let base64):
    if let detected = detectMediaType(base64: base64, topLevelType: "image") { mediaType = detected }
  case .url, .reference, .text:
    break
  }

  guard let mediaType else {
    throw InvalidArgumentError(argument: "mediaType", message: "Media type is missing for file part")
  }
  return LanguageModelV4FilePart(
    data: fileData, mediaType: mediaType, filename: filename, providerOptions: providerOptions)
}

private func convertToolResultOutput(_ output: ToolResultOutput, downloadedAssets: DownloadedAssets) throws
  -> LanguageModelV4ToolResultOutput
{
  switch output {
  case .text(let value, let options): return .text(value, providerOptions: options)
  case .json(let value, let options): return .json(value, providerOptions: options)
  case .executionDenied(let reason, let options): return .executionDenied(reason: reason, providerOptions: options)
  case .errorText(let value, let options): return .errorText(value, providerOptions: options)
  case .errorJSON(let value, let options): return .errorJSON(value, providerOptions: options)
  case .content(let parts):
    return .content(
      try parts.map { part in
        switch part {
        case .text(let text, let options):
          return .text(text, providerOptions: options)
        case .file(let data, let mediaType, let filename, let options):
          let converted = try convertFilePart(
            data: data, mediaType: mediaType, filename: filename, providerOptions: options,
            downloadedAssets: downloadedAssets)
          return .file(
            data: converted.data, mediaType: converted.mediaType, filename: converted.filename,
            providerOptions: converted.providerOptions)
        case .custom(let options):
          return .custom(providerOptions: options)
        }
      })
  }
}

private func convertToLanguageModelMessage(_ message: ModelMessage, downloadedAssets: DownloadedAssets) throws
  -> LanguageModelV4Message
{
  switch message {
  case .system(let system):
    return .system(system.content, providerOptions: system.providerOptions)

  case .user(let user):
    let parts: [LanguageModelV4UserContentPart] = try user.content.compactMap { part in
      switch part {
      case .text(let text):
        return text.text.isEmpty ? nil : .text(LanguageModelV4TextPart(text: text.text, providerOptions: text.providerOptions))
      case .image(let image):
        return .file(
          try convertFilePart(
            data: image.image, mediaType: image.mediaType ?? "image", filename: nil,
            providerOptions: image.providerOptions, downloadedAssets: downloadedAssets))
      case .file(let file):
        return .file(
          try convertFilePart(
            data: file.data, mediaType: file.mediaType, filename: file.filename,
            providerOptions: file.providerOptions, downloadedAssets: downloadedAssets))
      }
    }
    return .user(parts, providerOptions: user.providerOptions)

  case .assistant(let assistant):
    let parts: [LanguageModelV4AssistantContentPart] = try assistant.content.compactMap { part in
      switch part {
      case .text(let text):
        if text.text.isEmpty && text.providerOptions == nil { return nil }
        return .text(LanguageModelV4TextPart(text: text.text, providerOptions: text.providerOptions))
      case .custom(let custom):
        return .custom(LanguageModelV4CustomPart(kind: custom.kind, providerOptions: custom.providerOptions))
      case .file(let file):
        let normalized = normalizeFileData(file.data)
        return .file(
          LanguageModelV4FilePart(
            data: normalized.data, mediaType: normalized.mediaType ?? file.mediaType, filename: file.filename,
            providerOptions: file.providerOptions))
      case .reasoning(let reasoning):
        return .reasoning(LanguageModelV4ReasoningPart(text: reasoning.text, providerOptions: reasoning.providerOptions))
      case .reasoningFile(let file):
        let normalized = normalizeFileData(file.data)
        return .reasoningFile(
          LanguageModelV4ReasoningFilePart(
            data: normalized.data, mediaType: normalized.mediaType ?? file.mediaType,
            providerOptions: file.providerOptions))
      case .toolCall(let call):
        return .toolCall(
          LanguageModelV4ToolCallPart(
            toolCallId: call.toolCallId, toolName: call.toolName, input: call.input,
            providerExecuted: call.providerExecuted, providerOptions: call.providerOptions))
      case .toolResult(let result):
        return .toolResult(
          LanguageModelV4ToolResultPart(
            toolCallId: result.toolCallId, toolName: result.toolName,
            output: try convertToolResultOutput(result.output, downloadedAssets: downloadedAssets),
            providerOptions: result.providerOptions))
      case .toolApprovalRequest:
        return nil
      }
    }
    return .assistant(parts, providerOptions: assistant.providerOptions)

  case .tool(let tool):
    let parts: [LanguageModelV4ToolContentPart] = try tool.content.compactMap { part in
      switch part {
      case .toolResult(let result):
        return .toolResult(
          LanguageModelV4ToolResultPart(
            toolCallId: result.toolCallId, toolName: result.toolName,
            output: try convertToolResultOutput(result.output, downloadedAssets: downloadedAssets),
            providerOptions: result.providerOptions))
      case .toolApprovalResponse(let response):
        guard response.providerExecuted == true else { return nil }
        return .toolApprovalResponse(
          LanguageModelV4ToolApprovalResponsePart(
            approvalId: response.approvalId, approved: response.approved, reason: response.reason))
      }
    }
    return .tool(parts, providerOptions: tool.providerOptions)
  }
}

/// Converts a tool set to specification tools. Mirrors upstream `prepareTools`.
public func prepareTools(_ tools: ToolSet?, toolOrder: [String]? = nil) -> [LanguageModelV4Tool]? {
  guard let tools, !tools.isEmpty else { return nil }

  var entries = tools.map { (name: $0.name, tool: $0.tool) }
  if let toolOrder {
    let ordered = entries.filter { toolOrder.contains($0.name) }
      .sorted { toolOrder.firstIndex(of: $0.name)! < toolOrder.firstIndex(of: $1.name)! }
    let unordered = entries.filter { !toolOrder.contains($0.name) }.sorted { $0.name < $1.name }
    entries = ordered + unordered
  }

  return entries.map { name, tool in
    if let provider = tool.providerToolInfo {
      return .provider(LanguageModelV4ProviderTool(id: provider.id, name: name, args: provider.args))
    }
    return .function(
      LanguageModelV4FunctionTool(
        name: name, description: tool.description, inputSchema: tool.inputSchema.jsonSchema,
        inputExamples: tool.inputExamples, strict: tool.strict, providerOptions: tool.providerOptions))
  }
}
