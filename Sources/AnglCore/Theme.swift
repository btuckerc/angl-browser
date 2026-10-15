import Foundation

/// Chrome tokens. ~/.config/angl/theme.json overrides any subset; live-reloaded.
/// The same tokens are exported as CSS custom properties to angl:// pages.
public struct Theme: Codable, Equatable, Sendable {
    public var appearance: Appearance = .dark
    public var radius: Double = 0
    public var font = Fonts()
    public var color = Colors()
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
            public var muted = "#696969"
        }

        /// The border colour actually drawn: "auto" (or anything unparsable) mixes 35% accent into the base background.
        public var resolvedBorder: String {
            if parseHexColor(border) != nil { return border }
            guard let a = parseHexColor(accent), let b = parseHexColor(bg.base) else { return "#39545b" }
            func mix(_ x: Double, _ y: Double) -> Int { Int(((x * 0.35 + y * 0.65) * 255).rounded()) }
            return String(format: "#%02x%02x%02x", mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
        }
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

    public static func load(from url: URL) throws -> Theme {
        try JSONFile.layered(Theme(), file: url)
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
