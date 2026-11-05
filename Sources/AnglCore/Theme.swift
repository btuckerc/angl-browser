import Foundation

/// Chrome tokens. ~/.config/angl/theme.json overrides any subset; live-reloaded.
/// The same tokens are exported as CSS custom properties to angl:// pages.
public struct Theme: Codable, Equatable, Sendable {
    public var appearance: Appearance = .dark
    public var radius: Double = 0
    public var font = Fonts()
    /// The palette. In light appearance, `colorLight` is drawn instead: the built-in light palette
    /// with the user's appearance-neutral `color` keys and then their `colorLight` keys on top (see `layered(user:)`).
    public var color = Colors()
    public var colorLight = Colors.light
    public var metrics = Metrics()
    public var sidebar = Sidebar()
    public var window = Window()
    public var glyphs: Glyphs = .sf

    public init() {}

    public enum Appearance: String, Codable, Sendable { case dark, light, system }
    public enum Glyphs: String, Codable, Sendable { case sf, nerd }

    public struct Fonts: Codable, Equatable, Sendable {
        /// "system" = SF Pro; anything else is a font family name.
        public var ui = "system"
        public var mono = "MesloLGS Nerd Font Mono"
        public var size: Double = 12
    }

    public struct Colors: Codable, Equatable, Sendable {
        public var bg = Bg()
        public var fg = Fg()
        public var accent = "#55c3e8"
        public var ok = "#a6e25f"
        public var warn = "#ffdf6b"
        public var danger = "#ff8eaf"
        public var dangerStrong = "#e85b92"
        /// Hairlines and outlines. "auto" tints them with the accent; a hex colour pins them.
        public var border = "auto"
        public var workspaces = ["#55c3e8", "#a6e25f", "#ffdf6b", "#ff8eaf", "#e85b92", "#deddda", "#39545b"]

        public struct Bg: Codable, Equatable, Sendable {
            public var base = "#1d1d1d"
            public var sidebar = "#181818"
            public var raised = "#242424"
            public var selected = "#303030"
        }

        public struct Fg: Codable, Equatable, Sendable {
            public var primary = "#deddda"
            public var secondary = "#a3a29f"
            public var muted = "#8c8c8b"
        }

        /// The border colour actually drawn: "auto" (or anything unparsable) mixes 35% accent into the base background.
        public var resolvedBorder: String {
            if parseHexColor(border) != nil { return border }
            guard let a = parseHexColor(accent), let b = parseHexColor(bg.base) else { return "#39545b" }
            func mix(_ x: Double, _ y: Double) -> Int { Int(((x * 0.35 + y * 0.65) * 255).rounded()) }
            return String(format: "#%02x%02x%02x", mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
        }

        /// `hex` moved toward `fg.primary` only as far as it takes to reach `ratio` against the base,
        /// sidebar and raised backgrounds; when even the primary falls short, toward white or black,
        /// whichever reads better (and that extreme if nothing reaches). A colour that already passes, or doesn't parse, stays.
        func lifted(_ hex: String, to ratio: Double) -> String {
            guard let from = parseHexColor(hex) else { return hex }
            let backgrounds = [bg.base, bg.sidebar, bg.raised]
            func worst(_ c: String) -> Double { backgrounds.map { contrastRatio(c, $0) ?? 0 }.min() ?? 0 }
            if worst(hex) >= ratio { return hex }
            let extremes = ["#ffffff", "#000000"].sorted { worst($0) > worst($1) }
            for end in [fg.primary] + extremes {
                guard let to = parseHexColor(end) else { continue }
                // One step per 8-bit level, so no passing colour between two steps is skipped.
                for step in 1...255 {
                    let t = Double(step) / 255
                    func mix(_ x: Double, _ y: Double) -> Int { Int(((x * (1 - t) + y * t) * 255).rounded()) }
                    let candidate = String(format: "#%02x%02x%02x", mix(from.r, to.r), mix(from.g, to.g), mix(from.b, to.b))
                    if worst(candidate) >= ratio { return candidate }
                }
            }
            return extremes[0]
        }

        /// The colours drawn while macOS Increase Contrast is on: muted text reaches 4.5:1 against every
        /// background (WCAG AA), secondary text 7:1, hairlines 3:1.
        public var increasedContrast: Colors {
            var c = self
            c.fg.muted = lifted(fg.muted, to: 4.5)
            c.fg.secondary = lifted(fg.secondary, to: 7)
            c.border = lifted(resolvedBorder, to: 3)
            return c
        }

        /// The built-in light palette: every text colour reads at 4.5:1 or better on base, sidebar and raised.
        public static let light: Colors = {
            var c = Colors()
            c.bg = Bg(base: "#fafaf9", sidebar: "#f0efed", raised: "#ffffff", selected: "#e2e1de")
            c.fg = Fg(primary: "#1d1d1d", secondary: "#4a4946", muted: "#6b6a66")
            c.accent = "#0e759a"
            c.ok = "#3d7a17"
            c.warn = "#876800"
            c.danger = "#c0245d"
            c.dangerStrong = "#a01d4d"
            return c
        }()
    }

    public struct Metrics: Codable, Equatable, Sendable {
        public var navBar: Double = 36
        public var sidebarWidth: Double = 176
        public var row: Double = 24
        public var indent: Double = 12
        public var glyph: Double = 14
    }

    public struct Sidebar: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable { case pinned, hidden }
        public enum Edge: String, Codable, Sendable { case top, bottom, hidden }
        public var position = "left"
        public var mode: Mode = .pinned
        /// Where the Space selector sits in the sidebar.
        public var spaces: Edge = .top
        /// Width of the invisible strip at the window's left edge that reveals a hidden sidebar; 0 turns peeking off.
        public var peekWidth: Double = 10
        public var peekDelayMs: Double = 120
        public var hideDelayMs: Double = 400

        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Sidebar()
            position = try c.decodeIfPresent(String.self, forKey: .position) ?? d.position
            mode = (try? c.decode(Mode.self, forKey: .mode)) ?? d.mode
            spaces = (try? c.decode(Edge.self, forKey: .spaces)) ?? d.spaces
            peekWidth = max(0, min(40, try c.decodeIfPresent(Double.self, forKey: .peekWidth) ?? d.peekWidth))
            peekDelayMs = max(0, try c.decodeIfPresent(Double.self, forKey: .peekDelayMs) ?? d.peekDelayMs)
            hideDelayMs = max(0, try c.decodeIfPresent(Double.self, forKey: .hideDelayMs) ?? d.hideDelayMs)
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        public enum Address: String, Codable, Sendable { case palette, bar }
        /// What an empty tab shows in palette mode: the address field docked in the page, or only the wordmark.
        public enum NewTab: String, Codable, Sendable { case field, mark }
        /// The docked field's caret: the wordmark's block, or the system's.
        public enum Caret: String, Codable, Sendable { case block, native }
        public enum Outline: String, Codable, Sendable { case none, seam, content }
        public enum OutlineColor: String, Codable, Sendable { case accent, border, container, custom }
        public var address: Address = .palette
        public var newTab: NewTab = .field
        public var caret: Caret = .block
        /// Decoration placement; unknown legacy values deliberately decode to none.
        public var outline: Outline = .none
        public var outlineColor: OutlineColor = .accent
        public var outlineCustomColor = "#55c3e8"
        public var outlineWidth: Double = 0.5
        public var outlineOpacity: Double = 0.55
        public var outlineInactiveOpacity: Double = 0.15

        private enum CodingKeys: String, CodingKey { case address, newTab, caret, outline, outlineColor, outlineCustomColor, outlineWidth, outlineOpacity, outlineInactiveOpacity }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            address = try c.decodeIfPresent(Address.self, forKey: .address) ?? .palette
            newTab = (try? c.decode(NewTab.self, forKey: .newTab)) ?? .field
            caret = (try? c.decode(Caret.self, forKey: .caret)) ?? .block
            outline = (try? c.decode(Outline.self, forKey: .outline)) ?? .none
            outlineColor = try c.decodeIfPresent(OutlineColor.self, forKey: .outlineColor) ?? .accent
            outlineCustomColor = try c.decodeIfPresent(String.self, forKey: .outlineCustomColor) ?? "#55c3e8"
            outlineWidth = try c.decodeIfPresent(Double.self, forKey: .outlineWidth) ?? 0.5
            outlineOpacity = try c.decodeIfPresent(Double.self, forKey: .outlineOpacity) ?? 0.55
            outlineInactiveOpacity = try c.decodeIfPresent(Double.self, forKey: .outlineInactiveOpacity) ?? 0.15
        }
    }

    /// The theme with `Colors.increasedContrast`.
    public var increasedContrast: Theme {
        var t = self
        t.color = color.increasedContrast
        return t
    }

    /// The theme as drawn in one appearance: `color` is that appearance's palette and `appearance`
    /// says which (so `cssVariables` exports a definite `color-scheme`). In light, an accent under
    /// 4.5:1 on the backgrounds — a white accent chosen for dark — is darkened until it reaches 4.5:1:
    /// angl:// pages draw links in it.
    public func resolved(dark: Bool) -> Theme {
        var t = self
        t.appearance = dark ? .dark : .light
        if !dark {
            t.color = colorLight
            t.color.accent = colorLight.lifted(colorLight.accent, to: 4.5)
        }
        return t
    }

    /// `color` keys that also draw light. Backgrounds, text, status colours and a pinned border are
    /// chosen for dark: carried into light they can sit unreadably on (or vanish into) the light palette.
    static let sharedColorKeys: Set<String> = ["accent", "workspaces"]

    /// A partial user theme layered over the defaults. `color`'s `sharedColorKeys` are layered under
    /// the user's `colorLight`, which then goes over the light palette.
    public static func layered(user: Any) throws -> Theme {
        guard var u = user as? [String: Any], let color = u["color"] as? [String: Any] else { return try JSONFile.layered(Theme(), user: user) }
        let shared = color.filter { sharedColorKeys.contains($0.key) }
        u["colorLight"] = u["colorLight"].map { JSONFile.merge(shared, $0) } ?? shared
        return try JSONFile.layered(Theme(), user: u)
    }

    public static func load(from url: URL) throws -> Theme {
        try JSONFile.user(at: url).map(layered(user:)) ?? Theme()
    }

    /// `:root { --bg-base: …; … }` for internal pages and user CSS.
    public var cssVariables: String {
        var vars: [(String, String)] = [
            ("bg-base", color.bg.base), ("bg-sidebar", color.bg.sidebar),
            ("bg-raised", color.bg.raised), ("bg-selected", color.bg.selected),
            ("fg-primary", color.fg.primary), ("fg-secondary", color.fg.secondary), ("fg-muted", color.fg.muted),
            ("accent", color.accent),
            ("ok", color.ok), ("warn", color.warn), ("danger", color.danger), ("danger-strong", color.dangerStrong),
            ("border", color.resolvedBorder),
            ("radius", "\(radius)px"),
            ("font-ui", font.ui == "system" ? "-apple-system, system-ui, sans-serif" : "\"\(font.ui)\", -apple-system, sans-serif"),
            ("font-mono", "\"\(font.mono)\", \"SF Mono\", ui-monospace, monospace"),
            ("font-size", "\(font.size)px"),
            ("row", "\(metrics.row)px"),
        ]
        for (i, c) in color.workspaces.enumerated() { vars.append(("ws-\(i)", c)) }
        let body = vars.map { "  --\($0.0): \($0.1);" }.joined(separator: "\n")
        let scheme = appearance == .light ? "light" : appearance == .dark ? "dark" : "light dark"
        return ":root {\n  color-scheme: \(scheme);\n\(body)\n}\n"
    }
}

/// Parses "#rgb", "#rrggbb", "#rrggbbaa" into 0…1 components. Invalid input → nil.
public func parseHexColor(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    guard s.hasPrefix("#") else { return nil }
    s.removeFirst()
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
    if s.count == 6 {
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
    }
    return (Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
}

/// WCAG 2 contrast ratio of `a` drawn over `b` (1…21): a translucent `a` is blended into `b` first;
/// `b`'s own alpha is ignored (it is the opaque surface). Invalid input → nil.
public func contrastRatio(_ a: String, _ b: String) -> Double? {
    guard let f = parseHexColor(a), let g = parseHexColor(b) else { return nil }
    func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    func luminance(_ r: Double, _ gr: Double, _ bl: Double) -> Double { 0.2126 * lin(r) + 0.7152 * lin(gr) + 0.0722 * lin(bl) }
    func over(_ x: Double, _ y: Double) -> Double { x * f.a + y * (1 - f.a) }
    let la = luminance(over(f.r, g.r), over(f.g, g.g), over(f.b, g.b)), lb = luminance(g.r, g.g, g.b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}
