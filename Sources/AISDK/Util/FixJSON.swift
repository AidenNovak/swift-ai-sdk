import Foundation

/// Completes truncated JSON text (e.g. from a stream) into parsable JSON by
/// dropping trailing incomplete tokens and closing open strings, arrays and
/// objects. Mirrors upstream `fixJson`.
public func fixJson(_ input: String) -> String {
  enum State {
    case root, finish
    case insideString, insideStringEscape, insideStringUnicodeEscape
    case insideLiteral, insideNumber
    case insideObjectStart, insideObjectKey, insideObjectAfterKey, insideObjectBeforeValue
    case insideObjectAfterValue, insideObjectAfterComma
    case insideArrayStart, insideArrayAfterValue, insideArrayAfterComma
  }

  let chars = Array(input)
  var stack: [State] = [.root]
  var lastValidIndex = -1
  var literalStart: Int?
  var unicodeEscapeDigits = 0

  func processValueStart(_ char: Character, _ i: Int, _ swapState: State) {
    switch char {
    case "\"":
      lastValidIndex = i
      stack.removeLast()
      stack.append(swapState)
      stack.append(.insideString)
    case "f", "t", "n":
      lastValidIndex = i
      literalStart = i
      stack.removeLast()
      stack.append(swapState)
      stack.append(.insideLiteral)
    case "-":
      stack.removeLast()
      stack.append(swapState)
      stack.append(.insideNumber)
    case "0"..."9":
      lastValidIndex = i
      stack.removeLast()
      stack.append(swapState)
      stack.append(.insideNumber)
    case "{":
      lastValidIndex = i
      stack.removeLast()
      stack.append(swapState)
      stack.append(.insideObjectStart)
    case "[":
      lastValidIndex = i
      stack.removeLast()
      stack.append(swapState)
      stack.append(.insideArrayStart)
    default:
      break
    }
  }

  func processAfterObjectValue(_ char: Character, _ i: Int) {
    switch char {
    case ",":
      stack.removeLast()
      stack.append(.insideObjectAfterComma)
    case "}":
      lastValidIndex = i
      stack.removeLast()
    default:
      break
    }
  }

  func processAfterArrayValue(_ char: Character, _ i: Int) {
    switch char {
    case ",":
      stack.removeLast()
      stack.append(.insideArrayAfterComma)
    case "]":
      lastValidIndex = i
      stack.removeLast()
    default:
      break
    }
  }

  func partialLiteral(upTo end: Int) -> String {
    String(chars[(literalStart ?? 0)..<end])
  }

  for (i, char) in chars.enumerated() {
    guard let state = stack.last else { break }
    switch state {
    case .root:
      processValueStart(char, i, .finish)
    case .insideObjectStart:
      if char == "\"" {
        stack.removeLast()
        stack.append(.insideObjectKey)
      } else if char == "}" {
        lastValidIndex = i
        stack.removeLast()
      }
    case .insideObjectAfterComma:
      if char == "\"" {
        stack.removeLast()
        stack.append(.insideObjectKey)
      }
    case .insideObjectKey:
      if char == "\"" {
        stack.removeLast()
        stack.append(.insideObjectAfterKey)
      }
    case .insideObjectAfterKey:
      if char == ":" {
        stack.removeLast()
        stack.append(.insideObjectBeforeValue)
      }
    case .insideObjectBeforeValue:
      processValueStart(char, i, .insideObjectAfterValue)
    case .insideObjectAfterValue:
      processAfterObjectValue(char, i)
    case .insideString:
      switch char {
      case "\"":
        stack.removeLast()
        lastValidIndex = i
      case "\\":
        stack.append(.insideStringEscape)
      default:
        lastValidIndex = i
      }
    case .insideArrayStart:
      if char == "]" {
        lastValidIndex = i
        stack.removeLast()
      } else {
        lastValidIndex = i
        processValueStart(char, i, .insideArrayAfterValue)
      }
    case .insideArrayAfterValue:
      switch char {
      case ",":
        stack.removeLast()
        stack.append(.insideArrayAfterComma)
      case "]":
        lastValidIndex = i
        stack.removeLast()
      default:
        lastValidIndex = i
      }
    case .insideArrayAfterComma:
      processValueStart(char, i, .insideArrayAfterValue)
    case .insideStringEscape:
      stack.removeLast()
      if char == "u" {
        unicodeEscapeDigits = 0
        stack.append(.insideStringUnicodeEscape)
      } else {
        lastValidIndex = i
      }
    case .insideStringUnicodeEscape:
      if char.isHexDigit {
        unicodeEscapeDigits += 1
        if unicodeEscapeDigits == 4 {
          stack.removeLast()
          lastValidIndex = i
        }
      }
    case .insideNumber:
      switch char {
      case "0"..."9":
        lastValidIndex = i
      case "e", "E", "-", ".":
        break
      case ",":
        stack.removeLast()
        if stack.last == .insideArrayAfterValue { processAfterArrayValue(char, i) }
        if stack.last == .insideObjectAfterValue { processAfterObjectValue(char, i) }
      case "}":
        stack.removeLast()
        if stack.last == .insideObjectAfterValue { processAfterObjectValue(char, i) }
      case "]":
        stack.removeLast()
        if stack.last == .insideArrayAfterValue { processAfterArrayValue(char, i) }
      default:
        stack.removeLast()
      }
    case .insideLiteral:
      let partial = partialLiteral(upTo: i + 1)
      if !"false".hasPrefix(partial) && !"true".hasPrefix(partial) && !"null".hasPrefix(partial) {
        stack.removeLast()
        if stack.last == .insideObjectAfterValue {
          processAfterObjectValue(char, i)
        } else if stack.last == .insideArrayAfterValue {
          processAfterArrayValue(char, i)
        }
      } else {
        lastValidIndex = i
      }
    case .finish:
      break
    }
  }

  var result = String(chars[0..<(lastValidIndex + 1)])
  for state in stack.reversed() {
    switch state {
    case .insideString:
      result += "\""
    case .insideObjectKey, .insideObjectAfterKey, .insideObjectAfterComma, .insideObjectStart,
      .insideObjectBeforeValue, .insideObjectAfterValue:
      result += "}"
    case .insideArrayStart, .insideArrayAfterComma, .insideArrayAfterValue:
      result += "]"
    case .insideLiteral:
      let partial = partialLiteral(upTo: chars.count)
      for literal in ["true", "false", "null"] where literal.hasPrefix(partial) {
        result += literal.dropFirst(partial.count)
        break
      }
    default:
      break
    }
  }
  return result
}

/// The outcome of `parsePartialJson`. Mirrors upstream's result states.
public struct ParsePartialJSONResult: Sendable, Equatable {
  public enum State: Sendable, Equatable {
    case undefinedInput
    case successfulParse
    case repairedParse
    case failedParse
  }

  public var value: JSONValue?
  public var state: State
}

/// Parses JSON that may be truncated, repairing it with `fixJson` if needed.
/// Mirrors upstream `parsePartialJson`.
public func parsePartialJson(_ text: String?) -> ParsePartialJSONResult {
  guard let text else { return ParsePartialJSONResult(value: nil, state: .undefinedInput) }
  if let value = try? JSONValue(jsonString: text) {
    return ParsePartialJSONResult(value: value, state: .successfulParse)
  }
  if let value = try? JSONValue(jsonString: fixJson(text)) {
    return ParsePartialJSONResult(value: value, state: .repairedParse)
  }
  return ParsePartialJSONResult(value: nil, state: .failedParse)
}
