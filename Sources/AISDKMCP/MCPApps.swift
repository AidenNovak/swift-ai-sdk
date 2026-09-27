import AISDKProviderUtils
import Foundation

public let MCP_APP_EXTENSION_NAME = "io.modelcontextprotocol/ui"
public let MCP_APP_MIME_TYPE = "text/html;profile=mcp-app"
public let MCP_APP_LEGACY_RESOURCE_URI_META_KEY = "ui/resourceUri"

/// Client capabilities advertising MCP Apps support. Mirrors upstream `mcpAppClientCapabilities`.
public let mcpAppClientCapabilities: JSONObject = [
  "extensions": [MCP_APP_EXTENSION_NAME: ["mimeTypes": [.string(MCP_APP_MIME_TYPE)]]]
]

/// An MCP App's HTML resource. Mirrors upstream `MCPAppResource`.
public struct MCPAppResource: Sendable, Equatable {
  public var uri: String
  public var mimeType: String
  public var html: String
  /// `prefersBorder`, `csp` (`connectDomains`, `resourceDomains`, `frameDomains`) and `permissions`.
  public var meta: JSONObject?
}

/// The `ui` tool metadata with a validated `resourceUri`. Mirrors upstream `getMCPAppToolMeta`.
public func getMCPAppToolMeta(_ meta: JSONObject?) throws -> JSONObject? {
  let uiMeta = meta?["ui"]?.objectValue
  let resourceUri = uiMeta?["resourceUri"] ?? meta?[MCP_APP_LEGACY_RESOURCE_URI_META_KEY]
  let visibility = uiMeta?["visibility"]?.arrayValue.map { values in
    values.filter { $0 == "model" || $0 == "app" }
  }
  if let resourceUri {
    guard let uri = resourceUri.stringValue, uri.hasPrefix("ui://") else {
      throw MCPClientError(message: "Invalid MCP App resource URI: \(resourceUri.jsonString())")
    }
  } else if uiMeta == nil {
    return nil
  }
  var result = uiMeta ?? [:]
  if let resourceUri { result["resourceUri"] = resourceUri }
  if let visibility { result["visibility"] = .array(visibility) }
  return result
}

/// Splits tools into model-visible and app-visible sets. Mirrors upstream `splitMCPAppTools`.
public func splitMCPAppTools(_ definitions: MCPListToolsResult) throws -> (
  modelVisible: MCPListToolsResult, appVisible: MCPListToolsResult
) {
  var model: [MCPToolDefinition] = []
  var app: [MCPToolDefinition] = []
  for tool in definitions.tools {
    let visibility = try getMCPAppToolMeta(tool.meta)?["visibility"]?.arrayValue
    if visibility == nil || visibility?.contains("model") == true { model.append(tool) }
    if visibility?.contains("app") == true { app.append(tool) }
  }
  return (
    MCPListToolsResult(tools: model, nextCursor: definitions.nextCursor),
    MCPListToolsResult(tools: app, nextCursor: definitions.nextCursor)
  )
}

/// The distinct `ui://` resource URIs used by tools. Mirrors upstream `getMCPAppResourceUris`.
public func getMCPAppResourceUris(_ definitions: MCPListToolsResult) throws -> [String] {
  var seen: Set<String> = []
  var uris: [String] = []
  for tool in definitions.tools {
    if let uri = try getMCPAppToolMeta(tool.meta)?["resourceUri"]?.stringValue, seen.insert(uri).inserted {
      uris.append(uri)
    }
  }
  return uris
}

private func resourceUiMeta(_ meta: JSONValue?) -> JSONObject? {
  guard case .object(let ui)? = meta?["ui"] else { return nil }
  var result = ui
  if let border = ui["prefersBorder"], border.boolValue == nil { result["prefersBorder"] = nil }
  if let permissions = ui["permissions"], permissions.objectValue == nil { result["permissions"] = nil }
  if let csp = ui["csp"] {
    if case .object(var cspObject) = csp {
      for key in ["connectDomains", "resourceDomains", "frameDomains"] {
        if let values = cspObject[key] {
          cspObject[key] = values.arrayValue.map { .array($0.filter { $0.stringValue != nil }) }
        }
      }
      result["csp"] = .object(cspObject)
    } else {
      result["csp"] = nil
    }
  }
  return result
}

/// Extracts an MCP App from a `resources/read` result. Mirrors upstream `getMCPAppResourceFromReadResult`.
public func getMCPAppResource(uri: String, from result: MCPReadResourceResult) throws -> MCPAppResource {
  guard let content = result.contents.first(where: { $0["uri"]?.stringValue == uri }) else {
    throw MCPClientError(message: "MCP App resource not found in read result: \(uri)")
  }
  guard content["mimeType"]?.stringValue == MCP_APP_MIME_TYPE else {
    throw MCPClientError(
      message: "Unsupported MCP App resource MIME type: \(content["mimeType"]?.stringValue ?? "undefined")")
  }
  let html: String? =
    content["text"]?.stringValue
    ?? content["blob"]?.stringValue.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
  guard let html else { throw MCPClientError(message: "Unsupported MCP App resource content format: \(uri)") }
  return MCPAppResource(uri: uri, mimeType: MCP_APP_MIME_TYPE, html: html, meta: resourceUiMeta(content["_meta"]))
}

/// Reads an MCP App resource. Mirrors upstream `readMCPAppResource`.
public func readMCPAppResource(client: MCPClient, uri: String, options: MCPRequestOptions? = nil) async throws
  -> MCPAppResource
{
  guard uri.hasPrefix("ui://") else { throw MCPClientError(message: "Unsupported MCP App resource URI: \(uri)") }
  return try getMCPAppResource(uri: uri, from: try await client.readResource(uri: uri, options: options))
}

/// A stable fingerprint of an app's HTML and security metadata, for drift
/// detection. Mirrors upstream `fingerprintMCPAppResource`.
public func fingerprintMCPAppResource(_ resource: MCPAppResource) -> String {
  let canonical = jsonObject([
    "html": .string(resource.html), "csp": resource.meta?["csp"] ?? .null,
    "permissions": resource.meta?["permissions"] ?? .null,
  ]).jsonString()
  return base64URLEncoded(sha256(Data(canonical.utf8)))
}

/// Mirrors upstream `detectMCPAppResourceDrift`.
public func detectMCPAppResourceDrift(current: String, baseline: String) -> Bool {
  current != baseline
}
