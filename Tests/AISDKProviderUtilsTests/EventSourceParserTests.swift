import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKProviderUtils

@Suite struct EventSourceParserTests {
  @Test func parsesSimpleEvents() {
    var parser = EventSourceParser()
    let events = parser.feed("data: {\"a\":1}\n\ndata: second\n\n")
    #expect(events == [EventSourceMessage(data: "{\"a\":1}"), EventSourceMessage(data: "second")])
  }

  @Test func joinsMultiLineData() {
    var parser = EventSourceParser()
    #expect(parser.feed("data: line1\ndata: line2\n\n") == [EventSourceMessage(data: "line1\nline2")])
  }

  @Test func supportsEventTypesAndIds() {
    var parser = EventSourceParser()
    let events = parser.feed("event: message_start\nid: 7\ndata: {}\n\ndata: next\n\n")
    #expect(
      events == [
        EventSourceMessage(event: "message_start", data: "{}", id: "7"),
        EventSourceMessage(data: "next", id: "7"),
      ])
  }

  @Test func handlesCRLFAndCRLineEndings() {
    var parser = EventSourceParser()
    #expect(parser.feed("data: a\r\n\r\ndata: b\r\rdata: c\n\n").map(\.data) == ["a", "b", "c"])
  }

  @Test func handlesCRLFSplitAcrossChunks() {
    var parser = EventSourceParser()
    #expect(parser.feed("data: a\r").isEmpty)
    #expect(parser.feed("\n\r").map(\.data) == ["a"])
    #expect(parser.feed("\ndata: b\n\n").map(\.data) == ["b"])
  }

  @Test func handlesMultiByteCharactersSplitAcrossChunks() {
    var parser = EventSourceParser()
    let bytes = Array("data: café 你好\n\n".utf8)
    var events: [EventSourceMessage] = []
    for byte in bytes {
      events += parser.feed(Data([byte]))
    }
    #expect(events == [EventSourceMessage(data: "café 你好")])
  }

  @Test func ignoresCommentsUnknownFieldsAndEmptyEvents() {
    var parser = EventSourceParser()
    #expect(parser.feed(": keep-alive\nretry: 100\nfoo: bar\n\n\n").isEmpty)
  }

  @Test func stripsOnlyOneLeadingSpaceAndHandlesMissingColonSpace() {
    var parser = EventSourceParser()
    #expect(parser.feed("data:x\n\ndata:  y\n\n").map(\.data) == ["x", " y"])
  }

  @Test func stripsLeadingByteOrderMark() {
    var parser = EventSourceParser()
    #expect(parser.feed("\u{FEFF}data: a\n\n").map(\.data) == ["a"])
  }

  @Test func dropsIncompleteTrailingEvent() async throws {
    let events = try await collect(
      parseEventStream(HTTPBodyStream { continuation in
        continuation.yield(Data("data: complete\n\ndata: incomplete".utf8))
        continuation.finish()
      }))
    #expect(events.map(\.data) == ["complete"])
  }

  @Test func jsonEventStreamSkipsDoneAndReportsParseFailures() async throws {
    struct Chunk: Decodable, Sendable, Equatable { var value: String }
    let body = HTTPBodyStream { continuation in
      continuation.yield(Data("data: {\"value\":\"a\"}\n\ndata: {oops}\n\n".utf8))
      continuation.yield(Data("data: {\"other\":1}\n\ndata: [DONE]\n\n".utf8))
      continuation.finish()
    }
    let results = try await collect(parseJsonEventStream(body, as: Chunk.self))
    #expect(results.count == 3)
    #expect(results[0].value == Chunk(value: "a"))
    #expect(results[0].rawValue == ["value": "a"])
    #expect(results[1].error is JSONParseError)
    #expect(results[2].error is TypeValidationError)
    #expect(results[2].rawValue == ["other": 1])
  }
}
