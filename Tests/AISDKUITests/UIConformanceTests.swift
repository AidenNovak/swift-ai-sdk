import AISDK
import AISDKTestUtils
import Foundation
import Testing

private let fixture: JSONValue = {
  guard let url = Bundle.module.url(forResource: "ui-conformance", withExtension: "json", subdirectory: "Fixtures"),
    let data = try? Data(contentsOf: url), let json = try? JSONValue(jsonData: data)
  else { return [:] }
  return json
}()

private func cases(_ section: String) -> [JSONValue] { fixture[section]?.arrayValue ?? [] }
private func names(_ section: String) -> [String] { cases(section).compactMap { $0["name"]?.stringValue } }
private func testCase(_ section: String, _ name: String) -> JSONValue {
  cases(section).first { $0["name"]?.stringValue == name } ?? [:]
}

private func expectSame(_ expected: JSONValue?, _ actual: JSONValue?, _ label: String) {
  let differences = UpstreamConformance.differences(expected ?? .null, actual ?? .null)
  #expect(differences.isEmpty, "\(label): \(differences.joined(separator: "\n"))")
}

struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

/// The tool input validator of `Tools/conformance/ui-message-stream.mts`: `city` must be a string.
let citySchema = jsonSchema(
  ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]
) { value in
  guard value["city"]?.stringValue != nil else { throw TestFailure(description: "city must be a string") }
  return value
}

// MARK: - processUIMessageStream

private func eventJSON(_ event: UIMessageStreamEvent, message: UIMessage) -> JSONValue {
  switch event {
  case .write(let updateStatus):
    return ["type": "write", "updateStatus": .bool(updateStatus), "message": message.json]
  case .toolCall(let call):
    return ["type": "toolCall", "toolCall": UIMessageChunk.toolInputAvailable(call).json]
  case .data(let part):
    return ["type": "data", "part": UIMessagePart.data(part).json]
  case .error(let text):
    return ["type": "error", "message": .string(text)]
  }
}

@Test("processUIMessageStream matches upstream", arguments: names("process"))
func processConformance(name: String) throws {
  let expected = testCase("process", name)
  let initial = try expected["initialMessage"].map(UIMessage.init(json:))
  var state = StreamingUIMessageState(lastMessage: initial, messageId: "generated-id")
  var events: [JSONValue] = []
  var thrown: JSONValue?

  for chunkJSON in expected["chunks"]?.arrayValue ?? [] {
    let chunk = try UIMessageChunk(json: chunkJSON)
    do {
      for event in try state.apply(chunk) {
        events.append(eventJSON(event, message: state.message))
      }
    } catch let error as UIMessageStreamError {
      thrown = [
        "name": .string(error.name), "message": .string(error.message), "chunkType": .string(error.chunkType),
        "chunkId": .string(error.chunkId),
      ]
      break
    }
  }

  expectSame(expected["events"], .array(events), "events")
  expectSame(expected["thrown"], thrown, "thrown")
  expectSame(expected["message"], state.message.json, "message")
  expectSame(expected["finishReason"], state.finishReason.map { .string($0.rawValue) }, "finishReason")
}

@Test("UI message chunks round-trip through JSON", arguments: names("process"))
func chunkRoundTrip(name: String) throws {
  for chunkJSON in testCase("process", name)["chunks"]?.arrayValue ?? [] {
    expectSame(chunkJSON, try UIMessageChunk(json: chunkJSON).json, "chunk")
  }
}

// MARK: - streamText -> toUIMessageStream

private func makeTools(_ specs: JSONObject?) -> ToolSet {
  var tools: [(String, Tool)] = []
  for (name, spec) in specs ?? [:] {
    let output = spec["output"] ?? .null
    let failure = spec["error"]?.stringValue
    let execute: Tool.Execute = { _, _ in
      if let failure { throw TestFailure(description: failure) }
      return output
    }
    if spec["dynamic"]?.boolValue == true {
      tools.append((name, dynamicTool(inputSchema: ["type": "object"], execute: execute)))
    } else {
      var needsApproval: Tool.NeedsApproval?
      if spec["needsApproval"]?.boolValue == true {
        needsApproval = { @Sendable _, _ in true }
      }
      tools.append(
        (name, Tool(title: spec["title"]?.stringValue, inputSchema: citySchema, needsApproval: needsApproval, execute: execute)))
    }
  }
  return ToolSet(tools)
}

private func outcomeName(_ outcome: UIMessageStreamOutcome) -> String {
  switch outcome {
  case .completed: "completed"
  case .failed: "failed"
  case .aborted: "aborted"
  case .unknown: "unknown"
  }
}

private func endEventJSON(_ event: UIMessageStreamEndEvent) -> JSONValue {
  var json: JSONObject = [
    "isAborted": .bool(event.isAborted), "isContinuation": .bool(event.isContinuation),
    "outcome": .string(outcomeName(event.outcome)), "responseMessage": event.responseMessage.json,
    "messages": .array(event.messages.map(\.json)),
  ]
  if event.isCancelled { json["isCancelled"] = true }
  if let finishReason = event.finishReason { json["finishReason"] = .string(finishReason.rawValue) }
  return .object(json)
}

private final class Box<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

private func streamOptions(_ json: JSONValue?, onEnd: Box<JSONValue?>) throws -> UIMessageStreamOptions {
  var options = UIMessageStreamOptions()
  options.originalMessages = try json?["originalMessages"]?.arrayValue?.map { try UIMessage(json: $0) }
  if let messageId = json?["generateMessageId"]?.stringValue {
    options.generateMessageId = { @Sendable in messageId }
  }
  options.onEnd = { @Sendable event in onEnd.value = endEventJSON(event) }
  if let metadata = json?["messageMetadata"]?.objectValue {
    options.messageMetadata = { @Sendable part in metadata[part.type] }
  }
  options.sendReasoning = json?["sendReasoning"]?.boolValue ?? true
  options.sendSources = json?["sendSources"]?.boolValue ?? false
  options.sendFinish = json?["sendFinish"]?.boolValue ?? true
  options.sendStart = json?["sendStart"]?.boolValue ?? true
  return options
}

@Test("toUIMessageStream over streamText matches upstream", arguments: names("stream"))
func streamConformance(name: String) async throws {
  let expected = testCase("stream", name)
  let steps = try (expected["steps"]?.arrayValue ?? []).map { step in
    try (step.arrayValue ?? []).map(UpstreamConformance.streamPart)
  }
  let model = MockLanguageModelV4(doStream: .sequence(steps))
  let tools = makeTools(expected["tools"]?.objectValue)
  let result = streamText(
    model: model, prompt: .text("test"), tools: tools,
    stopWhen: [.isStepCount(expected["maxSteps"]?.intValue ?? 1)], generateId: { "gen-id" })

  let onEnd = Box<JSONValue?>(nil)
  let options = try streamOptions(expected["options"], onEnd: onEnd)
  let chunks = try await collect(result.toUIMessageStream(tools: tools, options: options))

  expectSame(expected["chunks"], .array(chunks.map(\.json)), "chunks")
  expectSame(expected["onEnd"], onEnd.value, "onEnd")
}

// MARK: - convertToModelMessages

/// Upstream writes URL file data in tagged form (`{type: 'url', url}`); the
/// Swift model message JSON uses the equivalent plain URL string.
private func untagURLFileData(_ json: JSONValue) -> JSONValue {
  switch json {
  case .array(let values):
    return .array(values.map(untagURLFileData))
  case .object(var object):
    if let data = object["data"], data["type"]?.stringValue == "url", let url = data["url"] {
      object["data"] = url
    }
    return .object(object.mapValues(untagURLFileData))
  default:
    return json
  }
}

@Test("convertToModelMessages matches upstream", arguments: names("convert"))
func convertConformance(name: String) async throws {
  let expected = testCase("convert", name)
  let messages = try (expected["messages"]?.arrayValue ?? []).map(UIMessage.init(json:))
  var convertDataPart: (@Sendable (DataUIPart) -> DataUIPartConversion?)?
  if expected["convertData"]?.boolValue == true {
    convertDataPart = { @Sendable part in
      part.name == "note" ? .text(TextPart(text: "Note: \(part.data.stringValue ?? "")")) : nil
    }
  }
  let modelMessages: [ModelMessage] = try await convertToModelMessages(
    messages, ignoreIncompleteToolCalls: expected["ignoreIncompleteToolCalls"]?.boolValue ?? false,
    convertDataPart: convertDataPart)
  expectSame(
    expected["modelMessages"].map(untagURLFileData), .array(modelMessages.map { $0.json }), "modelMessages")
}

// MARK: - validateUIMessages

private let createdAtSchema = jsonSchema(["type": "object"]) { value in
  guard value["createdAt"]?.doubleValue != nil else { throw TestFailure(description: "createdAt must be a number") }
  return value
}

@Test("validateUIMessages matches upstream", arguments: names("validate"))
func validateConformance(name: String) throws {
  let expected = testCase("validate", name)
  let result = safeValidateUIMessages(
    expected["messages"],
    metadataSchema: expected["metadataSchema"]?.boolValue == true ? createdAtSchema : nil,
    dataSchemas: expected["dataSchemas"]?.boolValue == true ? ["weather": citySchema] : nil,
    tools: expected["tools"]?.boolValue == true ? ["weather": Tool(inputSchema: citySchema)] : nil)

  switch result {
  case .success(let messages):
    #expect(expected["success"]?.boolValue == true, "expected failure \(expected["errorName"] ?? .null)")
    expectSame(expected["data"], .array(messages.map(\.json)), "data")
  case .failure(let error):
    #expect(expected["success"]?.boolValue == false, "unexpected failure: \(error)")
    #expect((error as? any AISDKError)?.name == expected["errorName"]?.stringValue)
  }
}

// MARK: - lastAssistantMessageIsComplete*

@Test("lastAssistantMessageIsComplete helpers match upstream", arguments: names("complete"))
func completeConformance(name: String) throws {
  let expected = testCase("complete", name)
  let messages = try (expected["messages"]?.arrayValue ?? []).map(UIMessage.init(json:))
  #expect(lastAssistantMessageIsCompleteWithToolCalls(messages) == expected["toolCalls"]?.boolValue)
  #expect(lastAssistantMessageIsCompleteWithApprovalResponses(messages) == expected["approvalResponses"]?.boolValue)
}

// MARK: - createUIMessageStream

private func runWriterOps(_ ops: [JSONValue], writer: UIMessageStreamWriter) async throws {
  for op in ops {
    if let chunk = op["write"] {
      writer.write(try UIMessageChunk(json: chunk))
    }
    if let chunks = op["merge"]?.arrayValue {
      writer.merge(streamFromArray(try chunks.map(UIMessageChunk.init(json:))))
    }
    if op["setOutcome"]?.stringValue == "completed" {
      writer.setOutcome(.completed)
    }
    if let message = op["throw"]?.stringValue {
      try await Task.sleep(for: .milliseconds(10))
      throw TestFailure(description: message)
    }
  }
}

private func stepEventJSON(_ event: UIMessageStreamStepEndEvent) -> JSONValue {
  [
    "isContinuation": .bool(event.isContinuation), "responseMessage": event.responseMessage.json,
    "messages": .array(event.messages.map(\.json)),
  ]
}

@Test("createUIMessageStream matches upstream", arguments: names("create"))
func createConformance(name: String) async throws {
  let expected = testCase("create", name)
  let ops = expected["ops"]?.arrayValue ?? []
  let prefix = expected["onError"]?.stringValue
  let onEnd = Box<JSONValue?>(nil)
  let stepEnds = Box<[JSONValue]>([])

  var onStepEnd: UIMessageStreamOnStepEnd?
  if expected["onStepEnd"]?.boolValue == true {
    onStepEnd = { @Sendable event in stepEnds.value.append(stepEventJSON(event)) }
  }
  let onError: @Sendable (any Error) -> String = { error in
    prefix.map { "\($0): \(error)" } ?? "An error occurred."
  }
  let stream = createUIMessageStream(
    onError: onError,
    originalMessages: try expected["originalMessages"]?.arrayValue?.map { try UIMessage(json: $0) },
    onStepEnd: onStepEnd,
    onEnd: { @Sendable event in onEnd.value = endEventJSON(event) },
    generateId: { @Sendable in "generated-message-id" },
    execute: { @Sendable writer in try await runWriterOps(ops, writer: writer) })

  let chunks: [UIMessageChunk] = try await collect(stream)
  expectSame(expected["chunks"], .array(chunks.map { $0.json }), "chunks")
  expectSame(expected["onEnd"], onEnd.value, "onEnd")
  expectSame(expected["stepEnds"], .array(stepEnds.value), "stepEnds")
}
