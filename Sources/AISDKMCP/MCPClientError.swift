import AISDKProviderUtils
import Foundation

/// An MCP client, transport or protocol error. Mirrors upstream `MCPClientError`.
public struct MCPClientError: AISDKError {
  public let name: String
  public let message: String
  public let cause: (any Error)?
  /// The JSON-RPC error `data`, when the server returned an error response.
  public let data: JSONValue?
  /// The JSON-RPC error code, when the server returned an error response.
  public let code: Int?
  public let statusCode: Int?
  public let url: String?
  public let responseBody: String?

  public init(
    name: String = "MCPClientError", message: String, cause: (any Error)? = nil, data: JSONValue? = nil,
    code: Int? = nil, statusCode: Int? = nil, url: String? = nil, responseBody: String? = nil
  ) {
    self.name = name
    self.message = message
    self.cause = cause
    self.data = data
    self.code = code
    self.statusCode = statusCode
    self.url = url
    self.responseBody = responseBody
  }
}
