import Foundation
import XCTest
@testable import AnglCore

final class SettingsTests: XCTestCase {
    /// Search keywords are the user's map whole (a removed default stays removed); other
    /// sections still layer key by key over the defaults.
    func testUserKeywordsReplaceDefaultsWhileOtherSectionsMerge() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"search":{"keywords":{"k":"https://kagi.com/search?q=%s"}},"content":{"zoom":1.25}}"#.utf8).write(to: file)
        let s = try Settings.load(from: file)
        XCTAssertEqual(s.search.keywords, ["k": "https://kagi.com/search?q=%s"])
        XCTAssertEqual(s.search.engine, Settings().search.engine)
        XCTAssertEqual(s.content.zoom, 1.25)
        XCTAssertEqual(s.content.javascript, Settings().content.javascript)
    }
}
