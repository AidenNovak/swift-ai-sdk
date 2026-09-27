import AISDK
import AISDKDeepSeek
import AISDKUI
import AppKit
import SwiftUI

/// A minimal native chat: an in-process agent with a weather tool and a tool
/// that needs the user's approval. Run with `DEEPSEEK_API_KEY=... swift run`.
@main
struct MacChatApp: App {
  init() {
    // Executables started from a terminal are background apps by default.
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
  }

  var body: some Scene {
    WindowGroup("MacChat") {
      ChatView()
        .frame(minWidth: 520, minHeight: 600)
    }
  }
}

private let weather = tool(
  description: "Get the current weather for a city.",
  inputSchema: jsonSchema(["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]])
) { input, _ in
  ["city": input["city"] ?? .null, "celsius": 23, "condition": "sunny"] as JSONValue
}

private let deleteNote = Tool(
  description: "Delete a note by title.",
  inputSchema: jsonSchema(["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]]),
  needsApproval: { _, _ in true },
  execute: { input, _ in ["deleted": input["title"] ?? .null] })

@MainActor
private func makeChat() -> Chat {
  let deepseek = createDeepSeek(
    DeepSeekProviderSettings(apiKey: ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]))
  let agent = ToolLoopAgent(
    model: deepseek("deepseek-flash"),
    instructions: "You are a concise assistant. Use tools when they help.",
    tools: ["weather": weather, "deleteNote": deleteNote])
  return Chat(
    transport: DirectChatTransport(agent: agent),
    throttle: .milliseconds(50),
    sendAutomaticallyWhen: { lastAssistantMessageIsCompleteWithApprovalResponses($0) })
}

struct ChatView: View {
  @State private var chat = makeChat()
  @State private var input = ""

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(chat.messages) { message in
              MessageView(message: message, chat: chat).id(message.id)
            }
          }
          .padding()
        }
        .onChange(of: chat.messages.last?.text) {
          proxy.scrollTo(chat.messages.last?.id, anchor: .bottom)
        }
      }

      if let error = chat.error {
        HStack {
          Text(error.localizedDescription).foregroundStyle(.red).lineLimit(2)
          Spacer()
          Button("Dismiss") { chat.clearError() }
        }
        .padding(.horizontal)
      }

      Divider()
      HStack {
        TextField("Ask something…", text: $input)
          .textFieldStyle(.roundedBorder)
          .onSubmit(send)
          .disabled(chat.status != .ready)
        if chat.status == .submitted || chat.status == .streaming {
          Button("Stop") { chat.stop() }
        } else {
          Button("Send", action: send).disabled(input.isEmpty)
        }
      }
      .padding()
    }
  }

  private func send() {
    let text = input
    guard !text.isEmpty else { return }
    input = ""
    Task { try await chat.sendMessage(text: text) }
  }
}

struct MessageView: View {
  let message: UIMessage
  let chat: Chat

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message.role == .user ? "You" : "Assistant").font(.caption).foregroundStyle(.secondary)
      ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
        switch part {
        case .text(let text):
          Text(text.text).textSelection(.enabled)
        case .reasoning(let reasoning):
          Text(reasoning.text).font(.callout).italic().foregroundStyle(.secondary)
        case .tool(let tool):
          ToolPartView(tool: tool, chat: chat)
        default:
          EmptyView()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

struct ToolPartView: View {
  let tool: ToolUIPart
  let chat: Chat

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("\(tool.toolName) · \(tool.state.rawValue)", systemImage: "wrench.and.screwdriver")
        .font(.caption.monospaced())
      if let input = tool.input {
        Text(input.jsonString()).font(.caption.monospaced()).foregroundStyle(.secondary)
      }
      if let output = tool.output {
        Text(output.jsonString()).font(.caption.monospaced())
      }
      if let errorText = tool.errorText {
        Text(errorText).font(.caption).foregroundStyle(.red)
      }
      if tool.state == .approvalRequested, let approval = tool.approval {
        HStack {
          Button("Approve") { Task { await chat.addToolApprovalResponse(id: approval.id, approved: true) } }
          Button("Deny", role: .destructive) {
            Task { await chat.addToolApprovalResponse(id: approval.id, approved: false, reason: "User denied") }
          }
        }
      }
    }
    .padding(8)
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}
