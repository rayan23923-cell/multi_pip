import Foundation
import Testing
@testable import TLFoundation

@Suite("JSONValue")
struct JSONValueTests {
    @Test func roundTripsNestedValues() throws {
        let value: JSONValue = [
            "name": "TaskLens",
            "count": 3,
            "ratio": 0.5,
            "enabled": true,
            "tags": ["a", "b"],
            "missing": nil,
        ]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func booleansStayBooleans() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("[true, 1]".utf8))
        #expect(decoded == .array([.bool(true), .number(1)]))
    }

    @Test func accessorsReturnTypedValues() {
        let value: JSONValue = ["n": 2, "s": "x", "b": false]
        #expect(value.objectValue?["n"]?.numberValue == 2)
        #expect(value.objectValue?["s"]?.stringValue == "x")
        #expect(value.objectValue?["b"]?.boolValue == false)
        #expect(value.stringValue == nil)
    }
}
