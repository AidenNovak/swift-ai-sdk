import Foundation

/// A server-sent event. Mirrors `EventSourceMessage` from `eventsource-parser`.
public struct EventSourceMessage: Sendable, Equatable {
  /// The event type, if the stream set one with `event:`.
  public var event: String?
  public var data: String
  /// The last event ID seen on the stream.
  public var id: String?

  public init(event: String? = nil, data: String, id: String? = nil) {
    self.event = event
    self.data = data
    self.id = id
  }
}

/// An incremental parser for the `text/event-stream` format.
///
/// Feed raw bytes as they arrive; complete events are returned as soon as
/// their terminating blank line is seen. Line splitting happens on bytes, so
/// multi-byte UTF-8 characters split across chunks are handled correctly.
public struct EventSourceParser: Sendable {
  private var lineBuffer: [UInt8] = []
  private var previousByteWasCR = false
  private var isFirstLine = true
  private var dataBuffer = ""
  private var eventType = ""
  private var lastEventId: String?

  public init() {}

  /// Parses a chunk of bytes and returns the events it completes.
  public mutating func feed(_ chunk: Data) -> [EventSourceMessage] {
    var events: [EventSourceMessage] = []
    for byte in chunk {
      if previousByteWasCR {
        previousByteWasCR = false
        if byte == 0x0A { continue }
      }
      switch byte {
      case 0x0A:
        processLine(into: &events)
      case 0x0D:
        previousByteWasCR = true
        processLine(into: &events)
      default:
        lineBuffer.append(byte)
      }
    }
    return events
  }

  /// Parses a chunk of text and returns the events it completes.
  public mutating func feed(_ text: String) -> [EventSourceMessage] {
    feed(Data(text.utf8))
  }

  private mutating func processLine(into events: inout [EventSourceMessage]) {
    var line = String(decoding: lineBuffer, as: UTF8.self)
    lineBuffer.removeAll(keepingCapacity: true)
    if isFirstLine {
      isFirstLine = false
      if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
    }

    if line.isEmpty {
      dispatch(into: &events)
      return
    }
    if line.hasPrefix(":") { return }

    let field: Substring
    var value: Substring
    if let colon = line.firstIndex(of: ":") {
      field = line[..<colon]
      value = line[line.index(after: colon)...]
      if value.hasPrefix(" ") { value = value.dropFirst() }
    } else {
      field = Substring(line)
      value = ""
    }

    switch field {
    case "data":
      dataBuffer += value
      dataBuffer += "\n"
    case "event":
      eventType = String(value)
    case "id":
      if !value.contains("\u{0}") { lastEventId = String(value) }
    default:
      break
    }
  }

  private mutating func dispatch(into events: inout [EventSourceMessage]) {
    defer {
      dataBuffer = ""
      eventType = ""
    }
    guard !dataBuffer.isEmpty else { return }
    let data = dataBuffer.hasSuffix("\n") ? String(dataBuffer.dropLast()) : dataBuffer
    events.append(
      EventSourceMessage(event: eventType.isEmpty ? nil : eventType, data: data, id: lastEventId))
  }
}

/// Parses a byte stream into server-sent events.
public func parseEventStream(_ stream: HTTPBodyStream) -> AsyncThrowingStream<
  EventSourceMessage, any Error
> {
  let (events, continuation) = AsyncThrowingStream<EventSourceMessage, any Error>.makeStream()
  let task = Task {
    var parser = EventSourceParser()
    do {
      for try await chunk in stream {
        for event in parser.feed(chunk) {
          continuation.yield(event)
        }
      }
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }
  return events
}

/// Parses a server-sent event stream whose events carry JSON data.
/// Mirrors upstream `parseJsonEventStream`. The `[DONE]` event is ignored.
public func parseJsonEventStream<T: Decodable & Sendable>(
  _ stream: HTTPBodyStream, as type: T.Type
) -> AsyncThrowingStream<ParseResult<T>, any Error> {
  let events = parseEventStream(stream)
  let (results, continuation) = AsyncThrowingStream<ParseResult<T>, any Error>.makeStream()
  let task = Task {
    do {
      for try await event in events where event.data != "[DONE]" {
        continuation.yield(safeParseJSON(event.data, as: T.self))
      }
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }
  return results
}
