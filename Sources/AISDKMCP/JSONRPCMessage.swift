import AISDKProviderUtils
import Foundation

/// A JSON-RPC request ID. Mirrors the upstream `string | number` union.
public enum JSONRPCID: Sendable, Hashable {
  case int(Int)
  case string(String)

  var json: JSONValue {
    switch self {
    case .int(let value): .number(Double(value))
    case .string(let value): .string(value)
    }
  }

  init?(json: JSONValue?) {
    switch json {
    case .number(let value)? where value == value.rounded(): self = .int(Int(value))
    case .string(let value)?: self = .string(value)
    default: return nil
    }
  }
}

/// The `error` member of a JSON-RPC error response.
public struct JSONRPCErrorObject: Sendable, Equatable {
  public var code: Int
  public var message: String
  public var data: JSONValue?

  public init(code: Int, message: String, data: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }
}

/// A JSON-RPC 2.0 message. Mirrors upstream `JSONRPCMessage`.
public enum JSONRPCMessage: Sendable, Equatable {
  case request(id: JSONRPCID, method: String, params: JSONObject? = nil)
  case notification(method: String, params: JSONObject? = nil)
  case response(id: JSONRPCID, result: JSONObject)
  case error(id: JSONRPCID?, error: JSONRPCErrorObject)

  public var json: JSONValue {
    switch self {
    case .request(let id, let method, let params):
      jsonObject(["jsonrpc": "2.0", "id": id.json, "method": .string(method), "params": params.map(JSONValue.object)])
    case .notification(let method, let params):
      jsonObject(["jsonrpc": "2.0", "method": .string(method), "params": params.map(JSONValue.object)])
    case .response(let id, let result):
      ["jsonrpc": "2.0", "id": id.json, "result": .object(result)]
    case .error(let id, let error):
      jsonObject([
        "jsonrpc": "2.0", "id": id?.json,
        "error": jsonObject(["code": .number(Double(error.code)), "message": .string(error.message), "data": error.data]),
      ])
    }
  }

  /// The message ID of a request or response.
  public var id: JSONRPCID? {
    switch self {
    case .request(let id, _, _), .response(let id, _): id
    case .error(let id, _): id
    case .notification: nil
    }
  }
}

private func invalid(_ value: JSONValue, _ reason: String) -> MCPClientError {
  MCPClientError(message: "Invalid JSON-RPC message: \(reason): \(value.jsonString(sortedKeys: false))")
}

private func checkKeys(_ object: JSONObject, allowed: Set<String>, _ value: JSONValue) throws {
  if let extra = object.keys.first(where: { !allowed.contains($0) }) {
    throw invalid(value, "unexpected key \"\(extra)\"")
  }
}

private func params(_ value: JSONValue?, _ message: JSONValue) throws -> JSONObject? {
  switch value {
  case nil: return nil
  case .object(let object)?:
    if let meta = object["_meta"], meta.objectValue == nil { throw invalid(message, "params._meta must be an object") }
    return object
  default: throw invalid(message, "params must be an object")
  }
}

/// Validates a parsed JSON value as a JSON-RPC message, rejecting unknown
/// top-level keys like upstream's strict schemas. Mirrors upstream `validateJSONRPCMessage`.
public func validateJSONRPCMessage(_ value: JSONValue) throws -> JSONRPCMessage {
  guard case .object(let object) = value, object["jsonrpc"] == "2.0" else {
    throw invalid(value, "expected an object with jsonrpc \"2.0\"")
  }
  let hasId = object["id"] != nil
  let id = JSONRPCID(json: object["id"])
  if hasId, id == nil { throw invalid(value, "id must be a string or integer") }

  if let method = object["method"] {
    guard let method = method.stringValue else { throw invalid(value, "method must be a string") }
    let parsedParams = try params(object["params"], value)
    if let id {
      try checkKeys(object, allowed: ["jsonrpc", "id", "method", "params"], value)
      return .request(id: id, method: method, params: parsedParams)
    }
    try checkKeys(object, allowed: ["jsonrpc", "method", "params"], value)
    return .notification(method: method, params: parsedParams)
  }

  if let result = object["result"] {
    guard let id else { throw invalid(value, "responses require an id") }
    guard case .object(let resultObject) = result else { throw invalid(value, "result must be an object") }
    try checkKeys(object, allowed: ["jsonrpc", "id", "result"], value)
    return .response(id: id, result: resultObject)
  }

  if case .object(let error)? = object["error"] {
    guard let code = error["code"]?.intValue, error["code"]?.doubleValue == Double(code),
      let message = error["message"]?.stringValue
    else { throw invalid(value, "error requires an integer code and a message") }
    try checkKeys(object, allowed: ["jsonrpc", "id", "error"], value)
    return .error(id: id, error: JSONRPCErrorObject(code: code, message: message, data: error["data"]))
  }

  throw invalid(value, "not a request, notification, response or error")
}

/// Parses and validates a JSON-RPC message. Mirrors upstream `parseJSONRPCMessage`.
public func parseJSONRPCMessage(_ text: String) throws -> JSONRPCMessage {
  try validateJSONRPCMessage(try parseJSON(text))
}
