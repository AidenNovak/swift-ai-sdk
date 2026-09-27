#if os(macOS) || os(Linux)
  import AISDKProviderUtils
  import Foundation

  /// Configuration for a local MCP server process. Mirrors upstream `StdioConfig`.
  public struct MCPStdioConfig: Sendable {
    public enum Stderr: Sendable {
      /// Forward to this process's stderr.
      case inherit
      /// Discard.
      case discard
      /// Write to a file handle.
      case fileHandle(FileHandle)
    }

    /// An executable path, or a name looked up in `PATH`.
    public var command: String
    public var args: [String]
    /// Extra environment variables; a safe subset of this process's
    /// environment (`HOME`, `PATH`, …) is inherited.
    public var env: [String: String]?
    public var stderr: Stderr
    public var cwd: String?

    public init(
      command: String, args: [String] = [], env: [String: String]? = nil, stderr: Stderr = .inherit, cwd: String? = nil
    ) {
      self.command = command
      self.args = args
      self.env = env
      self.stderr = stderr
      self.cwd = cwd
    }
  }

  /// The environment for an MCP server process. Mirrors upstream `getEnvironment`.
  func mcpStdioEnvironment(_ custom: [String: String]?, base: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String]
  {
    var env = custom ?? [:]
    for key in ["HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER"] where env[key] == nil {
      guard let value = base[key], !value.hasPrefix("()") else { continue }
      env[key] = value
    }
    return env
  }

  func resolveExecutable(_ command: String, path: String?) -> URL? {
    if command.contains("/") { return URL(fileURLWithPath: command) }
    for directory in (path ?? "").split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  /// Runs an MCP server as a child process, exchanging newline-delimited
  /// JSON-RPC over stdin/stdout. Mirrors upstream `StdioMCPTransport`.
  public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    public let supportsProtocolVersionDiscovery = true

    private let config: MCPStdioConfig
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var lineContinuation: AsyncStream<String>.Continuation?
    private var buffer = Data()
    private var handler: MCPTransportHandler?

    public init(_ config: MCPStdioConfig) {
      self.config = config
    }

    public func start(_ handler: MCPTransportHandler) async throws {
      if lock.withLock({ self.process != nil }) {
        throw MCPClientError(message: "StdioMCPTransport already started.")
      }
      let environment = mcpStdioEnvironment(config.env)
      guard let executable = resolveExecutable(config.command, path: environment["PATH"]) else {
        let error = MCPClientError(message: "Command not found: \(config.command)")
        await handler.onError(error)
        throw error
      }

      let process = Process()
      process.executableURL = executable
      process.arguments = config.args
      process.environment = environment
      if let cwd = config.cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

      let stdinPipe = Pipe()
      let stdoutPipe = Pipe()
      process.standardInput = stdinPipe
      process.standardOutput = stdoutPipe
      switch config.stderr {
      case .inherit: process.standardError = FileHandle.standardError
      case .discard: process.standardError = FileHandle.nullDevice
      case .fileHandle(let handle): process.standardError = handle
      }
      #if canImport(Darwin)
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
      #else
        signal(SIGPIPE, SIG_IGN)
      #endif

      let (lines, continuation) = AsyncStream<String>.makeStream()
      lock.withLock {
        self.handler = handler
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.lineContinuation = continuation
      }

      stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard let self else { return }
        if data.isEmpty {
          handle.readabilityHandler = nil
          self.lock.withLock { self.lineContinuation?.finish() }
          return
        }
        self.consume(data)
      }

      process.terminationHandler = { [weak self] _ in
        guard let self else { return }
        let continuation = self.lock.withLock { () -> AsyncStream<String>.Continuation? in
          self.process = nil
          return self.lineContinuation
        }
        continuation?.finish()
      }

      readerTask = Task {
        for await line in lines {
          do {
            await handler.onMessage(try parseJSONRPCMessage(line))
          } catch {
            await handler.onError(error)
          }
        }
        await handler.onClose()
      }

      do {
        try process.run()
      } catch {
        lock.withLock {
          self.process = nil
          self.lineContinuation?.finish()
        }
        await handler.onError(error)
        throw error
      }
    }

    private func consume(_ data: Data) {
      let lines = lock.withLock { () -> [String] in
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
          lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
          buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
      }
      let continuation = lock.withLock { lineContinuation }
      for line in lines { continuation?.yield(line) }
    }

    public func close() async throws {
      let process = lock.withLock { () -> Process? in
        let running = self.process
        self.process = nil
        buffer.removeAll()
        return running
      }
      try? stdinHandle?.close()
      if let process, process.isRunning { process.terminate() }
      lock.withLock { lineContinuation?.finish() }
    }

    public func send(_ message: JSONRPCMessage, options: MCPTransportSendOptions) async throws {
      guard let handle = lock.withLock({ process != nil ? stdinHandle : nil }) else {
        throw MCPClientError(message: "StdioClientTransport not connected")
      }
      var data = try message.json.jsonData(sortedKeys: false)
      data.append(UInt8(ascii: "\n"))
      try handle.write(contentsOf: data)
    }
  }
#endif
