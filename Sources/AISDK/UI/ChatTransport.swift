import Foundation

/// A request to send the chat messages. Mirrors the upstream `sendMessages` options.
public struct ChatSendMessagesRequest: Sendable {
  public enum Trigger: String, Sendable, Hashable {
    case submitMessage = "submit-message"
    case regenerateMessage = "regenerate-message"
  }

  public var trigger: Trigger
  public var chatId: String
  /// The message to regenerate or the edited user message, if any.
  public var messageId: String?
  public var messages: [UIMessage]
  public var options: ChatRequestOptions

  public init(
    trigger: Trigger, chatId: String, messageId: String?, messages: [UIMessage],
    options: ChatRequestOptions = ChatRequestOptions()
  ) {
    self.trigger = trigger
    self.chatId = chatId
    self.messageId = messageId
    self.messages = messages
    self.options = options
  }
}

/// A request to reconnect to an ongoing response stream.
public struct ChatReconnectRequest: Sendable {
  public var chatId: String
  public var options: ChatRequestOptions

  public init(chatId: String, options: ChatRequestOptions = ChatRequestOptions()) {
    self.chatId = chatId
    self.options = options
  }
}

/// Connects a chat to a backend. Mirrors upstream `ChatTransport`.
///
/// Cancelling the calling task (or terminating the returned stream) cancels the request.
public protocol ChatTransport: Sendable {
  /// Sends the messages and returns the response as a UI message stream.
  func sendMessages(_ request: ChatSendMessagesRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error>

  /// Reconnects to an ongoing response, or returns `nil` when there is none.
  func reconnectToStream(_ request: ChatReconnectRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error>?
}

// MARK: - HTTP

/// Options for preparing a send request. Mirrors upstream `PrepareSendMessagesRequest` options.
public struct PrepareSendMessagesRequestOptions: Sendable {
  public var id: String
  public var messages: [UIMessage]
  public var requestMetadata: JSONValue?
  public var body: JSONObject
  public var headers: [String: String]
  public var api: URL
  public var trigger: ChatSendMessagesRequest.Trigger
  public var messageId: String?
}

/// A prepared send request; `nil` fields keep the defaults.
public struct PreparedSendMessagesRequest: Sendable {
  public var body: JSONValue?
  public var headers: [String: String]?
  public var api: URL?

  public init(body: JSONValue? = nil, headers: [String: String]? = nil, api: URL? = nil) {
    self.body = body
    self.headers = headers
    self.api = api
  }
}

/// Options for preparing a reconnect request.
public struct PrepareReconnectToStreamRequestOptions: Sendable {
  public var id: String
  public var requestMetadata: JSONValue?
  public var body: JSONObject
  public var headers: [String: String]
  public var api: URL
}

/// A prepared reconnect request; `nil` fields keep the defaults.
public struct PreparedReconnectToStreamRequest: Sendable {
  public var headers: [String: String]?
  public var api: URL?

  public init(headers: [String: String]? = nil, api: URL? = nil) {
    self.headers = headers
    self.api = api
  }
}

/// Shared configuration of the HTTP chat transports. Mirrors upstream `HttpChatTransportInitOptions`.
public struct HTTPChatTransportOptions: Sendable {
  /// The chat endpoint. Reconnects use `{api}/{chatId}/stream`.
  public var api: URL
  /// Headers added to every request, resolved per request (e.g. fresh auth tokens).
  public var headers: @Sendable () async throws -> [String: String]
  /// Body fields added to every request, resolved per request.
  public var body: @Sendable () async throws -> JSONObject
  public var httpClient: any HTTPClient
  public var prepareSendMessagesRequest:
    (@Sendable (PrepareSendMessagesRequestOptions) async throws -> PreparedSendMessagesRequest)?
  public var prepareReconnectToStreamRequest:
    (@Sendable (PrepareReconnectToStreamRequestOptions) async throws -> PreparedReconnectToStreamRequest)?

  public init(
    api: URL,
    headers: [String: String] = [:],
    body: JSONObject = [:],
    httpClient: any HTTPClient = defaultHTTPClient,
    prepareSendMessagesRequest: (@Sendable (PrepareSendMessagesRequestOptions) async throws -> PreparedSendMessagesRequest)? =
      nil,
    prepareReconnectToStreamRequest: (
      @Sendable (PrepareReconnectToStreamRequestOptions) async throws -> PreparedReconnectToStreamRequest
    )? = nil
  ) {
    self.init(
      api: api, resolveHeaders: { headers }, resolveBody: { body }, httpClient: httpClient,
      prepareSendMessagesRequest: prepareSendMessagesRequest,
      prepareReconnectToStreamRequest: prepareReconnectToStreamRequest)
  }

  public init(
    api: URL,
    resolveHeaders: @escaping @Sendable () async throws -> [String: String],
    resolveBody: @escaping @Sendable () async throws -> JSONObject = { [:] },
    httpClient: any HTTPClient = defaultHTTPClient,
    prepareSendMessagesRequest: (@Sendable (PrepareSendMessagesRequestOptions) async throws -> PreparedSendMessagesRequest)? =
      nil,
    prepareReconnectToStreamRequest: (
      @Sendable (PrepareReconnectToStreamRequestOptions) async throws -> PreparedReconnectToStreamRequest
    )? = nil
  ) {
    self.api = api
    self.headers = resolveHeaders
    self.body = resolveBody
    self.httpClient = httpClient
    self.prepareSendMessagesRequest = prepareSendMessagesRequest
    self.prepareReconnectToStreamRequest = prepareReconnectToStreamRequest
  }
}

/// Appends a path to a URL, before any query or fragment.
func appendPathToURL(_ url: URL, _ path: String) -> URL {
  let string = url.absoluteString
  guard let index = string.firstIndex(where: { $0 == "?" || $0 == "#" }) else {
    return URL(string: string + path) ?? url
  }
  return URL(string: String(string[..<index]) + path + String(string[index...])) ?? url
}

func createUIAPICallError(_ response: HTTPResponse, url: URL, fallbackMessage: String) async -> APICallError {
  let body = (try? await response.bodyText()) ?? ""
  return APICallError(
    message: body.isEmpty ? fallbackMessage : body, url: url.absoluteString, requestBodyValues: nil,
    statusCode: response.statusCode, responseHeaders: response.headers, responseBody: body)
}

/// Sends and reconnects over HTTP; `processResponse` turns the body into chunks.
struct HTTPChatTransportCore: Sendable {
  let options: HTTPChatTransportOptions
  let processResponse: @Sendable (HTTPBodyStream) -> AsyncThrowingStream<UIMessageChunk, any Error>

  func sendMessages(_ request: ChatSendMessagesRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error> {
    let resolvedBody = try await options.body()
    let baseHeaders = combineHeaders(try await options.headers(), request.options.headers)
    let mergedBody = resolvedBody.merging(request.options.body ?? [:]) { _, new in new }

    let prepared = try await options.prepareSendMessagesRequest?(
      PrepareSendMessagesRequestOptions(
        id: request.chatId, messages: request.messages, requestMetadata: request.options.metadata, body: mergedBody,
        headers: baseHeaders, api: options.api, trigger: request.trigger, messageId: request.messageId))

    let api = prepared?.api ?? options.api
    let headers = prepared?.headers ?? baseHeaders
    var defaultBody = mergedBody
    defaultBody["id"] = .string(request.chatId)
    defaultBody["messages"] = .array(request.messages.map(\.json))
    defaultBody["trigger"] = .string(request.trigger.rawValue)
    if let messageId = request.messageId { defaultBody["messageId"] = .string(messageId) }
    let body = prepared?.body ?? .object(defaultBody)

    let response = try await options.httpClient.send(
      HTTPRequest(
        method: "POST", url: api, headers: combineHeaders(["content-type": "application/json"], headers),
        body: try body.jsonData(sortedKeys: false)))
    guard response.isOK else {
      throw await createUIAPICallError(response, url: api, fallbackMessage: "Failed to fetch the chat response.")
    }
    return processResponse(response.body)
  }

  func reconnectToStream(_ request: ChatReconnectRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error>? {
    let resolvedBody = try await options.body()
    let baseHeaders = combineHeaders(try await options.headers(), request.options.headers)
    let prepared = try await options.prepareReconnectToStreamRequest?(
      PrepareReconnectToStreamRequestOptions(
        id: request.chatId, requestMetadata: request.options.metadata,
        body: resolvedBody.merging(request.options.body ?? [:]) { _, new in new }, headers: baseHeaders,
        api: options.api))

    let api = prepared?.api ?? appendPathToURL(options.api, "/\(request.chatId)/stream")
    let response = try await options.httpClient.send(
      HTTPRequest(method: "GET", url: api, headers: prepared?.headers ?? baseHeaders))
    if response.statusCode == 204 { return nil }
    guard response.isOK else {
      throw await createUIAPICallError(response, url: api, fallbackMessage: "Failed to fetch the chat response.")
    }
    return processResponse(response.body)
  }
}

/// Talks to an endpoint that responds with the UI message stream protocol,
/// e.g. a Next.js route returning `toUIMessageStreamResponse()`.
/// Mirrors upstream `DefaultChatTransport`.
public struct DefaultChatTransport: ChatTransport {
  private let core: HTTPChatTransportCore

  public init(options: HTTPChatTransportOptions) {
    core = HTTPChatTransportCore(options: options, processResponse: parseUIMessageStream)
  }

  public init(api: URL, headers: [String: String] = [:], body: JSONObject = [:], httpClient: any HTTPClient = defaultHTTPClient) {
    self.init(options: HTTPChatTransportOptions(api: api, headers: headers, body: body, httpClient: httpClient))
  }

  public func sendMessages(_ request: ChatSendMessagesRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error> {
    try await core.sendMessages(request)
  }

  public func reconnectToStream(_ request: ChatReconnectRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error>? {
    try await core.reconnectToStream(request)
  }
}

/// Talks to an endpoint that responds with plain text, e.g.
/// `toTextStreamResponse()`. Mirrors upstream `TextStreamChatTransport`.
public struct TextStreamChatTransport: ChatTransport {
  private let core: HTTPChatTransportCore

  public init(options: HTTPChatTransportOptions) {
    core = HTTPChatTransportCore(options: options) { body in
      transformTextToUIMessageStream(decodeUTF8Stream(body))
    }
  }

  public init(api: URL, headers: [String: String] = [:], body: JSONObject = [:], httpClient: any HTTPClient = defaultHTTPClient) {
    self.init(options: HTTPChatTransportOptions(api: api, headers: headers, body: body, httpClient: httpClient))
  }

  public func sendMessages(_ request: ChatSendMessagesRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error> {
    try await core.sendMessages(request)
  }

  public func reconnectToStream(_ request: ChatReconnectRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error>? {
    try await core.reconnectToStream(request)
  }
}

// MARK: - Direct

/// Runs an agent in-process instead of calling a server: the natural
/// transport for a Mac app that talks to model providers directly.
/// Mirrors upstream `DirectChatTransport`.
///
/// ```swift
/// let agent = ToolLoopAgent(model: deepseek("deepseek-chat"), tools: tools)
/// let chat = Chat(transport: DirectChatTransport(agent: agent))
/// ```
public struct DirectChatTransport<AgentType: Agent>: ChatTransport {
  public let agent: AgentType
  /// Call options passed to the agent.
  public let options: JSONValue?
  public let uiMessageStreamOptions: UIMessageStreamOptions

  public init(agent: AgentType, options: JSONValue? = nil, uiMessageStreamOptions: UIMessageStreamOptions = UIMessageStreamOptions()) {
    self.agent = agent
    self.options = options
    self.uiMessageStreamOptions = uiMessageStreamOptions
  }

  public func sendMessages(_ request: ChatSendMessagesRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error> {
    let validated = try validateUIMessagesForAgent(request.messages, tools: agent.tools)
    let modelMessages = try await convertToModelMessages(validated, tools: agent.tools)
    let result = try await agent.stream(prompt: .messages(modelMessages), options: options)
    var streamOptions = uiMessageStreamOptions
    if streamOptions.originalMessages == nil {
      streamOptions.originalMessages = validated
    }
    return toUIMessageStream(result.fullStream, tools: agent.tools, options: streamOptions)
  }

  public func reconnectToStream(_ request: ChatReconnectRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error>? {
    nil
  }
}

// MARK: - Completion

/// The response format of a completion endpoint.
public enum CompletionStreamProtocol: String, Sendable {
  /// The UI message stream protocol; text deltas form the completion.
  case data
  /// Plain text.
  case text
}

/// Streams a completion from an endpoint that receives `{ prompt, ...body }`.
/// Mirrors the request part of upstream `callCompletionApi` (`useCompletion`).
///
/// - Parameter onUpdate: Receives the accumulated completion after each delta.
/// - Returns: The full completion.
public func callCompletionAPI(
  api: URL,
  prompt: String,
  headers: [String: String] = [:],
  body: JSONObject = [:],
  streamProtocol: CompletionStreamProtocol = .data,
  httpClient: any HTTPClient = defaultHTTPClient,
  onUpdate: @escaping @Sendable (String) async -> Void
) async throws -> String {
  var requestBody: JSONObject = ["prompt": .string(prompt)]
  requestBody.merge(body) { _, new in new }
  let response = try await httpClient.send(
    HTTPRequest(
      method: "POST", url: api,
      headers: withUserAgentSuffix(
        combineHeaders(["content-type": "application/json"], headers), "ai-sdk/swift", runtimeEnvironmentUserAgent),
      body: try JSONValue.object(requestBody).jsonData(sortedKeys: false)))
  guard response.isOK else {
    throw await createUIAPICallError(response, url: api, fallbackMessage: "Failed to fetch the chat response.")
  }

  var result = ""
  switch streamProtocol {
  case .text:
    for try await text in decodeUTF8Stream(response.body) {
      result += text
      await onUpdate(result)
    }
  case .data:
    for try await chunk in parseUIMessageStream(response.body) {
      switch chunk {
      case .textDelta(_, let delta, _):
        result += delta
        await onUpdate(result)
      case .error(let errorText):
        throw UIMessageStreamError(chunkType: "error", chunkId: "", message: errorText)
      default:
        break
      }
    }
  }
  return result
}
