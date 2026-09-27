/// Collects every element of an async sequence. Mirrors upstream
/// `convertAsyncIterableToArray` / `convertReadableStreamToArray`.
public func collect<S: AsyncSequence>(_ sequence: S) async throws -> [S.Element] {
  var elements: [S.Element] = []
  for try await element in sequence {
    elements.append(element)
  }
  return elements
}

/// Creates a finished stream from an array. Mirrors upstream `convertArrayToReadableStream`.
public func streamFromArray<Element: Sendable>(_ elements: [Element]) -> AsyncThrowingStream<
  Element, any Error
> {
  AsyncThrowingStream { continuation in
    for element in elements { continuation.yield(element) }
    continuation.finish()
  }
}
