import Foundation

/// The prompt of a generation call. Mirrors upstream `Prompt`.
public enum Prompt: Sendable, Equatable {
  /// A single user message.
  case text(String)
  /// A list of messages.
  case messages([ModelMessage])
}

extension Prompt: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = .text(value)
  }
}

/// System instructions. Mirrors upstream `Instructions`.
public enum Instructions: Sendable, Equatable {
  case text(String)
  case messages([SystemModelMessage])
}

extension Instructions: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = .text(value)
  }
}

/// A standardized prompt. Mirrors upstream `StandardizedPrompt`.
public struct StandardizedPrompt: Sendable, Equatable {
  public var instructions: Instructions?
  public var messages: [ModelMessage]
}

/// Validates and normalizes a prompt. Mirrors upstream `standardizePrompt`.
///
/// - Throws: `InvalidPromptError`.
public func standardizePrompt(
  instructions: Instructions?, prompt: Prompt, allowSystemInMessages: Bool = false
) throws -> StandardizedPrompt {
  let messages: [ModelMessage]
  switch prompt {
  case .text(let text):
    messages = [.user(text)]
  case .messages(let list):
    messages = list
  }

  if messages.isEmpty {
    throw InvalidPromptError(prompt: "[]", message: "messages must not be empty")
  }

  if !allowSystemInMessages, messages.contains(where: { $0.role == "system" }) {
    throw InvalidPromptError(
      prompt: String(describing: prompt),
      message:
        "System messages are not allowed in the prompt or messages fields. Use the instructions option instead.")
  }

  return StandardizedPrompt(instructions: instructions, messages: messages)
}
