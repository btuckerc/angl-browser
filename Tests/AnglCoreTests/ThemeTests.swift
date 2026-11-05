import XCTest
@testable import AnglCore

final class ThemeTests: XCTestCase {
    func testContrastRatioMatchesWCAG() throws {
        XCTAssertEqual(try XCTUnwrap(contrastRatio("#000000", "#ffffff")), 21, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(contrastRatio("#777777", "#777777")), 1, accuracy: 0.001)
        XCTAssertNil(contrastRatio("nope", "#ffffff"))
    }

    /// The default muted grey is 3.1:1 on the base background; Increase Contrast lifts every token to
    /// its floor on every background it's drawn over.
    func testIncreasedContrastLiftsDefaultsToTheirFloors() throws {
        let c = Theme.Colors()
        XCTAssertLessThan(try XCTUnwrap(contrastRatio(c.fg.muted, c.bg.base)), 4.5)
        let hc = c.increasedContrast
        for bg in [c.bg.base, c.bg.sidebar, c.bg.raised] {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(hc.fg.muted, bg)), 4.5)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(hc.fg.secondary, bg)), 7)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(hc.resolvedBorder, bg)), 3)
        }
        // Still a hierarchy: muted stays dimmer than secondary, secondary than primary.
        XCTAssertLessThan(try XCTUnwrap(contrastRatio(hc.fg.muted, c.bg.base)), try XCTUnwrap(contrastRatio(hc.fg.secondary, c.bg.base)))
        XCTAssertLessThan(try XCTUnwrap(contrastRatio(hc.fg.secondary, c.bg.base)), try XCTUnwrap(contrastRatio(hc.fg.primary, c.bg.base)))
    }

    /// A light theme moves toward its own (dark) primary; tokens that already pass are left alone.
    func testIncreasedContrastKeepsPassingColoursAndFollowsPrimary() {
        var c = Theme.Colors()
        c.bg = .init(base: "#ffffff", sidebar: "#f4f4f4", raised: "#fafafa", selected: "#e8e8e8")
        c.fg = .init(primary: "#111111", secondary: "#333333", muted: "#9a9a9a")
        c.border = "#222222"
        let hc = c.increasedContrast
        XCTAssertEqual(hc.fg.secondary, "#333333")
        XCTAssertEqual(hc.border, "#222222")
        XCTAssertNotEqual(hc.fg.muted, "#9a9a9a")
        XCTAssertGreaterThanOrEqual(contrastRatio(hc.fg.muted, "#f4f4f4") ?? 0, 4.5)
    }
}
