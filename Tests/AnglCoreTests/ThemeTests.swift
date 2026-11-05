import XCTest
@testable import AnglCore

final class ThemeTests: XCTestCase {
    func testContrastRatioMatchesWCAG() throws {
        XCTAssertEqual(try XCTUnwrap(contrastRatio("#000000", "#ffffff")), 21, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(contrastRatio("#777777", "#777777")), 1, accuracy: 0.001)
        XCTAssertNil(contrastRatio("nope", "#ffffff"))
        // A translucent foreground is measured as drawn: blended into the surface.
        XCTAssertEqual(try XCTUnwrap(contrastRatio("#ffffff00", "#1d1d1d")), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(contrastRatio("#00000080", "#ffffff")), try XCTUnwrap(contrastRatio("#7f7f7f", "#ffffff")), accuracy: 0.01)
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
        // A primary that can't carry the floors itself: the lift goes on toward white.
        var dim = Theme.Colors()
        dim.fg = .init(primary: "#8c8c8b", secondary: "#8c8c8b", muted: "#8c8c8b")
        let hd = dim.increasedContrast
        for bg in [dim.bg.base, dim.bg.sidebar, dim.bg.raised] {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(hd.fg.muted, bg)), 4.5)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(hd.fg.secondary, bg)), 7)
        }
        // Transparent tokens count as invisible, not as their opaque colour.
        var clear = Theme.Colors()
        clear.fg.muted = "#ffffff00"; clear.fg.secondary = "#ffffff00"; clear.border = "#ffffff00"
        let hcl = clear.increasedContrast
        for bg in [clear.bg.base, clear.bg.sidebar, clear.bg.raised] {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(hcl.fg.muted, bg)), 4.5)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(hcl.fg.secondary, bg)), 7)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(hcl.resolvedBorder, bg)), 3)
        }
        // Black and white surfaces leave two greys that pass both (#757575, #767676);
        // the lift finds one instead of giving up on an extreme that is 1:1 against one of them.
        var split = Theme.Colors()
        split.bg = .init(base: "#000000", sidebar: "#ffffff", raised: "#000000", selected: "#222222")
        split.fg = .init(primary: "#dedede", secondary: "#a3a29f", muted: "#8c8c8c")
        let band = split.increasedContrast.fg.muted
        for bg in ["#000000", "#ffffff"] {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(band, bg)), 4.5, band)
        }
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

    /// `color` draws dark; only its appearance-neutral keys (accent, Space colours) reach light, where
    /// `colorLight` keys win. Backgrounds, text and status colours chosen for dark stay out of light.
    func testColorLayersUnderColorLight() throws {
        let t = try Theme.layered(user: [
            "color": ["accent": "#ffffff", "workspaces": ["#123456"], "warn": "#111111", "bg": ["base": "#101010"], "fg": ["primary": "#f0f0f0"]],
            "colorLight": ["warn": "#222222", "bg": ["sidebar": "#eeeeee"]],
        ])
        XCTAssertEqual(t.color.accent, "#ffffff")
        XCTAssertEqual(t.color.warn, "#111111")
        XCTAssertEqual(t.color.bg.base, "#101010")
        XCTAssertEqual(t.colorLight.accent, "#ffffff")
        XCTAssertEqual(t.colorLight.workspaces, ["#123456"])
        XCTAssertEqual(t.colorLight.warn, "#222222")
        XCTAssertEqual(t.colorLight.bg.sidebar, "#eeeeee")
        XCTAssertEqual(t.colorLight.bg.base, Theme.Colors.light.bg.base)
        XCTAssertEqual(t.colorLight.fg, Theme.Colors.light.fg)
        XCTAssertEqual(t.resolved(dark: true).color, t.color)
        XCTAssertEqual(t.resolved(dark: false).color.warn, "#222222")
    }

    /// Every accent swatch Settings offers, picked for dark, reads as link text in light (4.5:1 on the
    /// light backgrounds) and still marks the selected row (3:1). An accent that already passes is drawn as written.
    func testLightAccentReadsAsText() throws {
        for hex in ["#ffffff", "#55c3e8", "#f5d90a", "#ff4fa3"] {
            let light = try Theme.layered(user: ["color": ["accent": hex]]).resolved(dark: false).color
            for bg in [light.bg.base, light.bg.sidebar, light.bg.raised] {
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(light.accent, bg)), 4.5, hex)
            }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(contrastRatio(light.accent, light.bg.selected)), 3, hex)
        }
        XCTAssertEqual(try Theme.layered(user: ["color": ["accent": "#ffffff"]]).resolved(dark: true).color.accent, "#ffffff")
        XCTAssertEqual(Theme().resolved(dark: false).color.accent, Theme.Colors.light.accent)
    }
}
