import Foundation

/// Collects values from concurrent callbacks.
public final class Recorder<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Value] = []

  public init() {}

  public func append(_ value: Value) {
    lock.withLock { storage.append(value) }
  }

  public var values: [Value] { lock.withLock { storage } }
}
