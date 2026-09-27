import Foundation

/// An HTTP call to a provider API failed. Mirrors upstream `APICallError`.
public struct APICallError: AISDKError {
  public let name = "AI_APICallError"
  public let message: String
  public let url: String
  public let requestBodyValues: JSONValue?
  public let statusCode: Int?
  public let responseHeaders: [String: String]?
  public let responseBody: String?
  public let isRetryable: Bool
  public let data: JSONValue?
  public let cause: (any Error)?

  public init(
    message: String,
    url: String,
    requestBodyValues: JSONValue?,
    statusCode: Int? = nil,
    responseHeaders: [String: String]? = nil,
    responseBody: String? = nil,
    cause: (any Error)? = nil,
    isRetryable: Bool? = nil,
    data: JSONValue? = nil
  ) {
    self.message = message
    self.url = url
    self.requestBodyValues = requestBodyValues
    self.statusCode = statusCode
    self.responseHeaders = responseHeaders
    self.responseBody = responseBody
    self.cause = cause
    self.isRetryable = isRetryable ?? Self.defaultIsRetryable(statusCode: statusCode)
    self.data = data
  }

  /// Request timeout (408), conflict (409), too many requests (429) and
  /// server errors (5xx) are retryable.
  public static func defaultIsRetryable(statusCode: Int?) -> Bool {
    guard let statusCode else { return false }
    return statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
  }
}

/// The response body was empty. Mirrors upstream `EmptyResponseBodyError`.
public struct EmptyResponseBodyError: AISDKError {
  public let name = "AI_EmptyResponseBodyError"
  public let message: String

  public init(message: String = "Empty response body") {
    self.message = message
  }
}

/// A function argument is invalid. Mirrors upstream `InvalidArgumentError`.
public struct InvalidArgumentError: AISDKError {
  public let name = "AI_InvalidArgumentError"
  public let message: String
  public let argument: String
  public let cause: (any Error)?

  public init(argument: String, message: String, cause: (any Error)? = nil) {
    self.argument = argument
    self.message = message
    self.cause = cause
  }
}

/// A prompt is invalid. Mirrors upstream `InvalidPromptError`.
public struct InvalidPromptError: AISDKError {
  public let name = "AI_InvalidPromptError"
  public let message: String
  /// A textual rendering of the offending prompt.
  public let prompt: String
  public let cause: (any Error)?

  public init(prompt: String, message: String, cause: (any Error)? = nil) {
    self.prompt = prompt
    self.message = "Invalid prompt: \(message)"
    self.cause = cause
  }
}

/// The server returned a response with invalid data content.
/// Mirrors upstream `InvalidResponseDataError`.
public struct InvalidResponseDataError: AISDKError {
  public let name = "AI_InvalidResponseDataError"
  public let message: String
  public let data: JSONValue?

  public init(data: JSONValue?, message: String? = nil) {
    self.data = data
    self.message = message ?? "Invalid response data: \((data ?? .null).jsonString())."
  }
}

/// JSON text could not be parsed. Mirrors upstream `JSONParseError`.
public struct JSONParseError: AISDKError {
  public let name = "AI_JSONParseError"
  public let message: String
  public let text: String
  public let cause: (any Error)?

  public init(text: String, cause: (any Error)?) {
    self.text = text
    self.cause = cause
    self.message = "JSON parsing failed: Text: \(text).\nError message: \(getErrorMessage(cause))"
  }
}

/// An API key could not be loaded. Mirrors upstream `LoadAPIKeyError`.
public struct LoadAPIKeyError: AISDKError {
  public let name = "AI_LoadAPIKeyError"
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

/// A setting could not be loaded. Mirrors upstream `LoadSettingError`.
public struct LoadSettingError: AISDKError {
  public let name = "AI_LoadSettingError"
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

/// The model produced no content. Mirrors upstream `NoContentGeneratedError`.
public struct NoContentGeneratedError: AISDKError {
  public let name = "AI_NoContentGeneratedError"
  public let message: String

  public init(message: String = "No content generated.") {
    self.message = message
  }
}

/// A provider does not have the requested model. Mirrors upstream `NoSuchModelError`.
public struct NoSuchModelError: AISDKError {
  public enum ModelType: String, Sendable, Hashable {
    case languageModel
    case embeddingModel
    case imageModel
    case transcriptionModel
    case speechModel
    case rerankingModel
    case videoModel
    case evaluationModel
  }

  public let name: String
  public let message: String
  public let modelId: String
  public let modelType: ModelType

  public init(
    errorName: String = "AI_NoSuchModelError",
    modelId: String,
    modelType: ModelType,
    message: String? = nil
  ) {
    self.name = errorName
    self.modelId = modelId
    self.modelType = modelType
    self.message = message ?? "No such \(modelType.rawValue): \(modelId)"
  }
}

/// A provider reference does not contain an entry for the provider.
/// Mirrors upstream `NoSuchProviderReferenceError`.
public struct NoSuchProviderReferenceError: AISDKError {
  public let name = "AI_NoSuchProviderReferenceError"
  public let message: String
  public let provider: String
  public let reference: SharedV4ProviderReference

  public init(provider: String, reference: SharedV4ProviderReference, message: String? = nil) {
    self.provider = provider
    self.reference = reference
    self.message =
      message
      ?? "No provider reference found for provider '\(provider)'. Available providers: \(reference.keys.sorted().joined(separator: ", "))"
  }
}

/// Too many values were passed to a single embedding call.
/// Mirrors upstream `TooManyEmbeddingValuesForCallError`.
public struct TooManyEmbeddingValuesForCallError: AISDKError {
  public let name = "AI_TooManyEmbeddingValuesForCallError"
  public let message: String
  public let provider: String
  public let modelId: String
  public let maxEmbeddingsPerCall: Int
  public let values: [String]

  public init(provider: String, modelId: String, maxEmbeddingsPerCall: Int, values: [String]) {
    self.provider = provider
    self.modelId = modelId
    self.maxEmbeddingsPerCall = maxEmbeddingsPerCall
    self.values = values
    self.message =
      "Too many values for a single embedding call. The \(provider) model \"\(modelId)\" can only embed up to \(maxEmbeddingsPerCall) values per call, but \(values.count) values were provided."
  }
}

/// Context for a type validation failure. Mirrors upstream `TypeValidationContext`.
public struct TypeValidationContext: Sendable, Hashable {
  public var field: String?
  public var entityName: String?
  public var entityId: String?

  public init(field: String? = nil, entityName: String? = nil, entityId: String? = nil) {
    self.field = field
    self.entityName = entityName
    self.entityId = entityId
  }
}

/// A value did not match the expected type. Mirrors upstream `TypeValidationError`.
public struct TypeValidationError: AISDKError {
  public let name = "AI_TypeValidationError"
  public let message: String
  public let value: JSONValue?
  public let context: TypeValidationContext?
  public let cause: (any Error)?

  public init(value: JSONValue?, cause: (any Error)?, context: TypeValidationContext? = nil) {
    self.value = value
    self.cause = cause
    self.context = context

    var prefix = "Type validation failed"
    if let field = context?.field {
      prefix += " for \(field)"
    }
    if context?.entityName != nil || context?.entityId != nil {
      var parts: [String] = []
      if let entityName = context?.entityName { parts.append(entityName) }
      if let entityId = context?.entityId { parts.append("id: \"\(entityId)\"") }
      prefix += " (\(parts.joined(separator: ", ")))"
    }
    self.message =
      "\(prefix): Value: \((value ?? .null).jsonString()).\nError message: \(getErrorMessage(cause))"
  }

  /// Wraps an error in a `TypeValidationError`, reusing `cause` when it is
  /// already a matching `TypeValidationError`.
  public static func wrap(
    value: JSONValue?, cause: any Error, context: TypeValidationContext? = nil
  ) -> TypeValidationError {
    if let existing = cause as? TypeValidationError, existing.value == value,
      existing.context == context
    {
      return existing
    }
    return TypeValidationError(value: value, cause: cause, context: context)
  }
}

/// The requested functionality is not supported. Mirrors upstream `UnsupportedFunctionalityError`.
public struct UnsupportedFunctionalityError: AISDKError {
  public let name = "AI_UnsupportedFunctionalityError"
  public let message: String
  public let functionality: String

  public init(functionality: String, message: String? = nil) {
    self.functionality = functionality
    self.message = message ?? "'\(functionality)' functionality not supported."
  }
}
