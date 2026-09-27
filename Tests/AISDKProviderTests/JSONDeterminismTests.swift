import Foundation
import Testing

@testable import AISDKProvider

@Suite struct JSONDeterminismTests {
  @Test func serializationIsStableRegardlessOfInsertionOrder() throws {
    var forward: JSONObject = [:]
    var backward: JSONObject = [:]
    let keys = (0..<50).map { "key\($0)" }
    for key in keys { forward[key] = .string(key) }
    for key in keys.reversed() { backward[key] = .string(key) }

    let a = JSONValue.object(["nested": .object(forward)])
    let b = JSONValue.object(["nested": .object(backward)])
    #expect(a.jsonString() == b.jsonString())
    #expect(try a.jsonData() == b.jsonData())
  }
}
