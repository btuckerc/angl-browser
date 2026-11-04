import Foundation
import XCTest
@testable import AnglCore
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

final class ScriptletLibraryTests: XCTestCase {
    private func vendored() throws -> ScriptletLibrary {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/web/inject/adguard-scriptlets.js")
        return ScriptletLibrary(try String(contentsOf: url, encoding: .utf8))
    }

    /// A page's cut of the vendored bundle runs on its own: the scriptlets its rules name work
    /// (aliases included), and others aren't registered.
    func testSubsetOfVendoredBundleRunsRequestedScriptlets() throws {
        #if canImport(JavaScriptCore)
        let subset = try vendored().source(for: ["set-constant", "ubo-set-constant.js", "json-prune"])
        let ctx = try XCTUnwrap(JSContext())
        // Just enough of a page for these scriptlets: a window, its Window class and location.
        ctx.evaluateScript("var window = this; function Window() {}; window.location = { href: 'https://example.com/' };")
        ctx.evaluateScript(subset)
        XCTAssertNil(ctx.exception)
        let invoke = { (call: String) in ctx.evaluateScript("window.__anglAdGuardScriptlets.invoke(\(call))")?.toBool() }
        XCTAssertEqual(invoke("'set-constant', ['anglProbe', 'true']"), true)
        XCTAssertEqual(ctx.evaluateScript("window.anglProbe")?.toBool(), true)
        XCTAssertEqual(invoke("'ubo-set-constant.js', ['anglAlias', 'false']"), true)
        XCTAssertEqual(ctx.evaluateScript("window.anglAlias === false")?.toBool(), true)
        XCTAssertEqual(invoke("'json-prune', ['ads']"), true)
        XCTAssertEqual(ctx.evaluateScript("JSON.stringify(JSON.parse('{\"ads\":1,\"keep\":2}'))")?.toString(), "{\"keep\":2}")
        XCTAssertEqual(invoke("'abort-on-property-read', ['x']"), false)
        XCTAssertNil(ctx.exception)
        #else
        throw XCTSkip("needs JavaScriptCore")
        #endif
    }

    func testBundleInAnUnknownShapeIsKeptWhole() {
        let source = "(() => { window.x = 1; })();"
        XCTAssertEqual(ScriptletLibrary(source).source(for: ["set-constant"]), source)
    }
}
