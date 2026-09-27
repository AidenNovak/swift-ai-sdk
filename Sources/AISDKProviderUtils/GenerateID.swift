/// Generates IDs. Mirrors upstream `IdGenerator`.
public typealias IdGenerator = @Sendable () -> String

/// Creates an ID generator. Mirrors upstream `createIdGenerator`.
///
/// - Throws: `InvalidArgumentError` when a prefix is used and the separator is
///   part of the alphabet.
public func createIdGenerator(
  prefix: String? = nil,
  separator: String = "-",
  size: Int = 16,
  alphabet: String = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
) throws -> IdGenerator {
  let characters = Array(alphabet)
  let generator: IdGenerator = {
    var rng = SystemRandomNumberGenerator()
    return String((0..<size).map { _ in characters[Int.random(in: 0..<characters.count, using: &rng)] })
  }

  guard let prefix else { return generator }

  if alphabet.contains(separator) {
    throw InvalidArgumentError(
      argument: "separator",
      message: "The separator \"\(separator)\" must not be part of the alphabet \"\(alphabet)\".")
  }
  return { "\(prefix)\(separator)\(generator())" }
}

/// Generates a 16-character random ID. Mirrors upstream `generateId`.
public let generateId: IdGenerator = {
  // Without a prefix, createIdGenerator cannot throw.
  try! createIdGenerator()
}()
