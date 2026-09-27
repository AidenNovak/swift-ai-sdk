import Foundation

/// Base protocol for all errors thrown by swift-ai-sdk. Mirrors upstream `AISDKError`.
///
/// Upstream identifies error classes with `isInstance` markers; in Swift use
/// pattern matching (`catch let error as APICallError`) instead.
public protocol AISDKError: Error, CustomStringConvertible, LocalizedError {
  /// The error name, e.g. `AI_APICallError`.
  var name: String { get }
  /// A human-readable message.
  var message: String { get }
  /// The underlying cause, if any.
  var cause: (any Error)? { get }
}

extension AISDKError {
  public var cause: (any Error)? { nil }
  public var description: String { "\(name): \(message)" }
  public var errorDescription: String? { message }
}

/// Returns a readable message for any error-like value. Mirrors upstream `getErrorMessage`.
public func getErrorMessage(_ error: Any?) -> String {
  switch error {
  case nil:
    return "unknown error"
  case let string as String:
    return string
  case let json as JSONValue:
    return json.jsonString()
  case let error as any AISDKError:
    return error.description
  case let error as any Error:
    return String(describing: error)
  case let value?:
    return String(describing: value)
  }
}
