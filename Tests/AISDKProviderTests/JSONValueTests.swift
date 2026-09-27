import Foundation
import Testing

@testable import AISDKProvider

@Suite struct JSONValueTests {
  @Test func parsesAllValueKinds() throws {
    let value = try JSONValue(jsonString: #"{"a":1,"b":true,"c":"x","d":null,"e":[1.5,false],"f":{"g":0}}"#)
    #expect(value["a"] == .number(1))
    #expect(value["b"] == .bool(true))
    #expect(value["c"] == .string("x"))
    #expect(value["d"] == .null)
    #expect(value["e"] == [1.5, false])
    #expect(value["f"]?["g"]?.intValue == 0)
  }

  @Test func booleansAreNotDecodedAsNumbers() throws {
    #expect(try JSONValue(jsonString: "true") == .bool(true))
    #expect(try JSONValue(jsonString: "1") == .number(1))
    #expect(try JSONValue(jsonString: "0") == .number(0))
  }

  @Test func integralNumbersEncodeWithoutFraction() {
    let value: JSONValue = ["n": 42, "f": 1.5, "big": 1e20]
    #expect(value.jsonString(sortedKeys: true) == #"{"big":1e+20,"f":1.5,"n":42}"#)
  }

  @Test func roundTripsThroughJSONText() throws {
    let value: JSONValue = ["list": [1, "two", nil, ["nested": true]], "url": "https://x.dev/a"]
    let text = value.jsonString(sortedKeys: true)
    #expect(text == #"{"list":[1,"two",null,{"nested":true}],"url":"https://x.dev/a"}"#)
    #expect(try JSONValue(jsonString: text) == value)
  }

  @Test func convertsFromEncodableAndDecodesBack() throws {
    struct Weather: Codable, Equatable {
      var city: String
      var celsius: Int
    }
    let value = try JSONValue(encoding: Weather(city: "Beijing", celsius: 25))
    #expect(value == ["city": "Beijing", "celsius": 25])
    #expect(try value.decode(as: Weather.self) == Weather(city: "Beijing", celsius: 25))
  }

  @Test func accessorsReturnNilForMismatchedKinds() {
    let value: JSONValue = "text"
    #expect(value.intValue == nil)
    #expect(value.objectValue == nil)
    #expect(value["key"] == nil)
    #expect(value[0] == nil)
    #expect(JSONValue.number(1.5).intValue == nil)
  }

  @Test func invalidJSONThrows() {
    #expect(throws: (any Error).self) { try JSONValue(jsonString: "{invalid") }
  }
}
