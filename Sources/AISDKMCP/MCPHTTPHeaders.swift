import AISDKProviderUtils
import Foundation

/// A tool argument sent as an `Mcp-Param-*` header (`x-mcp-header`).
/// Mirrors upstream `MCPToolHeaderBinding`.
struct MCPToolHeaderBinding: Sendable, Equatable {
  enum ValueType: String, Sendable {
    case boolean, integer, string
  }

  var headerName: String
  var path: [String]
  var valueType: ValueType
}

private let httpTokenCharacters = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

private func isHTTPToken(_ value: String) -> Bool {
  !value.isEmpty && value.allSatisfy { httpTokenCharacters.contains($0) }
}

/// Encodes non-ASCII or padded values as `=?base64?...?=`. Mirrors upstream `encodeMCPHeaderValue`.
func encodeMCPHeaderValue(_ value: String) -> String {
  let isPlainAscii = value.unicodeScalars.allSatisfy { $0.value == 0x09 || (0x20...0x7E).contains($0.value) }
  let looksEncoded = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
  if isPlainAscii, value.trimmingCharacters(in: .whitespacesAndNewlines) == value, !looksEncoded {
    return value
  }
  return "=?base64?\(Data(value.utf8).base64EncodedString())?="
}

/// Collects `x-mcp-header` annotations from a tool input schema.
/// Mirrors upstream `getMCPToolHeaderBindings`.
func getMCPToolHeaderBindings(_ inputSchema: JSONValue) -> Result<[MCPToolHeaderBinding], MCPClientError> {
  guard case .object = inputSchema else {
    return .failure(MCPClientError(message: "inputSchema must be a JSON Schema object"))
  }
  var bindings: [MCPToolHeaderBinding] = []
  var headerNames: Set<String> = []
  var error: String?

  func visit(_ value: JSONValue, _ path: [String], _ staticallyReachable: Bool) {
    guard error == nil else { return }
    if case .array(let items) = value {
      for item in items { visit(item, path, false) }
      return
    }
    guard case .object(let object) = value else { return }
    if let header = object["x-mcp-header"] {
      guard staticallyReachable, !path.isEmpty else {
        error = "x-mcp-header is not on a statically reachable property"
        return
      }
      guard let headerName = header.stringValue, isHTTPToken(headerName) else {
        error = "x-mcp-header must be a non-empty HTTP token"
        return
      }
      guard !headerNames.contains(headerName.lowercased()) else {
        error = "x-mcp-header value \"\(headerName)\" is not unique"
        return
      }
      guard let valueType = object["type"]?.stringValue.flatMap(MCPToolHeaderBinding.ValueType.init(rawValue:)) else {
        error = "x-mcp-header can only annotate boolean, integer, or string properties"
        return
      }
      headerNames.insert(headerName.lowercased())
      bindings.append(MCPToolHeaderBinding(headerName: headerName, path: path, valueType: valueType))
    }
    for key in object.keys.sorted() where key != "x-mcp-header" {
      let child = object[key] ?? .null
      if key == "properties", case .object(let properties) = child {
        for name in properties.keys.sorted() {
          visit(properties[name] ?? .null, path + [name], staticallyReachable)
        }
      } else {
        visit(child, path, false)
      }
    }
  }

  visit(inputSchema, [], true)
  if let error { return .failure(MCPClientError(message: error)) }
  return .success(bindings)
}

/// Builds `Mcp-Param-*` headers for a tool call. Mirrors upstream `createMCPToolHeaders`.
func createMCPToolHeaders(bindings: [MCPToolHeaderBinding], args: JSONObject) throws -> [String: String] {
  var headers: [String: String] = [:]
  for binding in bindings {
    var current: JSONValue? = .object(args)
    for segment in binding.path {
      guard case .object(let object)? = current else {
        current = nil
        break
      }
      current = object[segment]
    }
    guard let value = current, value != .null else { continue }
    let text: String
    switch (binding.valueType, value) {
    case (.string, .string(let string)): text = string
    case (.boolean, .bool(let bool)): text = bool ? "true" : "false"
    case (.integer, .number(let number)) where number == number.rounded() && abs(number) <= 9_007_199_254_740_991:
      text = String(Int(number))
    default:
      throw MCPClientError(message: "Tool argument \"\(binding.path.joined(separator: "."))\" does not match its x-mcp-header type")
    }
    headers["Mcp-Param-\(binding.headerName)"] = encodeMCPHeaderValue(text)
  }
  return headers
}
