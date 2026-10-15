import Foundation
import XCTest
import FilterEngine
@testable import AnglCore

final class FilterListConverterTests: XCTestCase {
    func testNetworkBlockAndExceptionAreConvertedBySafariConverter() throws {
        let output = FilterListConverter.convert(["||ads.example^", "@@||ads.example/allowed^"])
        let chunks = try XCTUnwrap(output.chunks.first)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chunks.utf8)) as? [[String: Any]])
        XCTAssertTrue(rules.contains { ($0["action"] as? [String: String])?["type"] == "block" })
        XCTAssertTrue(rules.contains { ($0["action"] as? [String: String])?["type"] == "ignore-previous-rules" })
    }

    func testEmptyConversionProducesValidNonemptyRuleList() throws {
        let output = FilterListConverter.convert([""])
        XCTAssertEqual(output.chunks.count, 1)
        XCTAssertEqual(output.ruleCount, 1)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output.chunks.first).utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual((rules[0]["action"] as? [String: String])?["type"], "ignore-previous-rules")
    }

    func testChunksPackConvertedRulesAndRepeatGlobalExceptions() throws {
        let rules = (0..<5).map { "||ad\($0).example^" } + ["@@||allowed.example^"]
        let output = FilterListConverter.convert([rules.joined(separator: "\n")], maxRulesPerList: 3)
        XCTAssertEqual(output.chunks.count, 3)
        XCTAssertEqual(output.ruleCount, 8)
        for chunk in output.chunks {
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chunk.utf8)) as? [[String: Any]])
            XCTAssertLessThanOrEqual(decoded.count, 3)
            XCTAssertTrue(decoded.contains { ($0["action"] as? [String: String])?["type"] == "ignore-previous-rules" })
        }
    }

    func testScriptletBecomesDomainIndexedAdvancedEntry() throws {
        let output = FilterListConverter.convert(["youtube.com#%#//scriptlet('json-prune', 'adPlacements')"])
        XCTAssertEqual(output.advancedRuleCount, 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("rules")
        let index = directory.appendingPathComponent("index")
        let lines = output.advancedRulesText.split(whereSeparator: \.isNewline).map(String.init)
        let storage = try FilterRuleStorage(from: lines, for: .safari26, fileURL: source)
        try FilterEngine(storage: storage).write(to: index)

        let matching = try FilterListConverter.advancedEntries(for: URL(string: "https://www.youtube.com/watch?v=x")!, storageURL: source, indexURL: index)
        let unrelated = try FilterListConverter.advancedEntries(for: URL(string: "https://example.org/")!, storageURL: source, indexURL: index)
        XCTAssertEqual(matching, [.init(kind: .scriptlet, content: "//scriptlet('json-prune', 'adPlacements')")])
        let invocation = try XCTUnwrap(FilterListConverter.scriptletInvocation(matching[0].content))
        XCTAssertEqual(invocation.name, "json-prune")
        XCTAssertEqual(invocation.arguments, ["adPlacements"])
        XCTAssertTrue(unrelated.isEmpty)
    }
}
