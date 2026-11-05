import XCTest
@testable import AnglCore

final class ThemeTests: XCTestCase {
    func testContrastRatioMatchesWCAG() throws {
        XCTAssertEqual(try XCTUnwrap(contrastRatio("#000000", "#ffffff")), 21, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(contrastRatio("#777777", "#777777")), 1, accuracy: 0.001)
        XCTAssertNil(contrastRatio("nope", "#ffffff"))
    }

    /// Default text, including the status colours toasts and pages draw as text, reads at WCAG AA
    /// (4.5:1) on every background it's drawn over, dark and light; Increase Contrast lifts every token to its floor.
    func testIncreasedContrastLiftsDefaultsToTheirFloors() throws {
        for p in [Theme.Colors(), Theme.Colors.light] {
            for bg in [p.bg.base, p.bg.sidebar, p.bg.raised] {
                for fg in [p.fg.primary, p.fg.secondary, p.fg.muted, p.accent, p.ok, p.warn, p.danger] {
                    XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(fg, bg)), 4.5, "\(fg) on \(bg)")
                }
            }
        }
        let c = Theme.Colors()
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

    /// `color` keys reach both appearances, `colorLight` keys only light (and win there); keys the
    /// user didn't write keep each palette's own defaults.
    func testColorLayersUnderColorLight() throws {
        let t = try Theme.layered(user: [
            "color": ["accent": "#ffffff", "warn": "#111111"],
            "colorLight": ["warn": "#222222", "bg": ["base": "#eeeeee"]],
        ])
        XCTAssertEqual(t.color.accent, "#ffffff")
        XCTAssertEqual(t.color.warn, "#111111")
        XCTAssertEqual(t.color.bg.base, Theme.Colors().bg.base)
        XCTAssertEqual(t.colorLight.accent, "#ffffff")
        XCTAssertEqual(t.colorLight.warn, "#222222")
        XCTAssertEqual(t.colorLight.bg.base, "#eeeeee")
        XCTAssertEqual(t.colorLight.bg.sidebar, Theme.Colors.light.bg.sidebar)
        XCTAssertEqual(t.resolved(dark: true).color, t.color)
        XCTAssertEqual(t.resolved(dark: false).color.warn, "#222222")
    }

    /// A white accent picked for dark still reads as a highlight in light: lifted to 3:1 on the light
    /// backgrounds. An accent that already passes is drawn as written.
    func testLightAccentIsFlooredAtThreeToOne() throws {
        let white = try Theme.layered(user: ["color": ["accent": "#ffffff"]]).resolved(dark: false)
        for bg in [white.color.bg.base, white.color.bg.sidebar, white.color.bg.raised] {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(white.color.accent, bg)), 3)
        }
        XCTAssertEqual(try Theme.layered(user: ["color": ["accent": "#ffffff"]]).resolved(dark: true).color.accent, "#ffffff")
        XCTAssertEqual(Theme().resolved(dark: false).color.accent, Theme.Colors.light.accent)
    }
}
