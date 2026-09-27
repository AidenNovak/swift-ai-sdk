import AISDK
import Foundation
import Observation

/// An observable text completion for SwiftUI. Mirrors `useCompletion` from `@ai-sdk/react`.
///
/// The endpoint receives `{ "prompt": ..., ...body }` and responds with the UI
/// message stream protocol (`.data`) or plain text (`.text`).
@MainActor
public final class Completion: Observable {
  private let registrar = ObservationRegistrar()
  private var storedCompletion: String
  private var storedInput: String
  private var storedIsLoading = false
  private var storedError: (any Error)?
  private var activeTask: Task<String?, Never>?

  public let id: String
  public let api: URL
  public var headers: [String: String]
  public var body: JSONObject
  public var streamProtocol: CompletionStreamProtocol
  public var httpClient: any HTTPClient
  /// Called with the prompt and the completion when a request finishes.
  public var onFinish: (@MainActor (String, String) -> Void)?
  public var onError: (@MainActor (any Error) -> Void)?

  public init(
    api: URL,
    id: String? = nil,
    initialInput: String = "",
    initialCompletion: String = "",
    headers: [String: String] = [:],
    body: JSONObject = [:],
    streamProtocol: CompletionStreamProtocol = .data,
    httpClient: any HTTPClient = defaultHTTPClient,
    onFinish: (@MainActor (String, String) -> Void)? = nil,
    onError: (@MainActor (any Error) -> Void)? = nil
  ) {
    self.api = api
    self.id = id ?? generateId()
    self.storedInput = initialInput
    self.storedCompletion = initialCompletion
    self.headers = headers
    self.body = body
    self.streamProtocol = streamProtocol
    self.httpClient = httpClient
    self.onFinish = onFinish
    self.onError = onError
  }

  /// The completion so far.
  public var completion: String {
    get {
      registrar.access(self, keyPath: \.completion)
      return storedCompletion
    }
    set { registrar.withMutation(of: self, keyPath: \.completion) { storedCompletion = newValue } }
  }

  /// The prompt input, e.g. bound to a `TextField`.
  public var input: String {
    get {
      registrar.access(self, keyPath: \.input)
      return storedInput
    }
    set { registrar.withMutation(of: self, keyPath: \.input) { storedInput = newValue } }
  }

  public private(set) var isLoading: Bool {
    get {
      registrar.access(self, keyPath: \.isLoading)
      return storedIsLoading
    }
    set { registrar.withMutation(of: self, keyPath: \.isLoading) { storedIsLoading = newValue } }
  }

  public private(set) var error: (any Error)? {
    get {
      registrar.access(self, keyPath: \.error)
      return storedError
    }
    set { registrar.withMutation(of: self, keyPath: \.error) { storedError = newValue } }
  }

  /// Requests a completion for `prompt`, replacing any running request.
  ///
  /// - Returns: The completion, or `nil` when it was stopped or failed.
  @discardableResult
  public func complete(_ prompt: String, headers: [String: String]? = nil, body: JSONObject? = nil) async -> String? {
    activeTask?.cancel()
    isLoading = true
    error = nil
    completion = ""

    let requestHeaders = combineHeaders(self.headers, headers)
    let requestBody = self.body.merging(body ?? [:]) { _, new in new }
    let task = Task { [api, streamProtocol, httpClient] () -> String? in
      do {
        let result = try await callCompletionAPI(
          api: api, prompt: prompt, headers: requestHeaders, body: requestBody, streamProtocol: streamProtocol,
          httpClient: httpClient
        ) { [weak self] text in
          await self?.update(text)
        }
        try Task.checkCancellation()
        return result
      } catch {
        if Task.isCancelled || isCancellationError(error) { return nil }
        self.fail(error)
        return nil
      }
    }
    activeTask = task
    let result = await task.value

    guard activeTask == task else { return result }
    activeTask = nil
    isLoading = false
    if let result { onFinish?(prompt, result) }
    return result
  }

  /// Requests a completion for the current `input`.
  @discardableResult
  public func submit() async -> String? {
    await complete(input)
  }

  /// Stops the running request.
  public func stop() {
    activeTask?.cancel()
  }

  private func update(_ text: String) {
    guard !(activeTask?.isCancelled ?? true) else { return }
    completion = text
  }

  private func fail(_ error: any Error) {
    onError?(error)
    self.error = error
  }
}
