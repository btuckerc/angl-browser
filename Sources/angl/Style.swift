import AnglCore
import AppKit

/// Theme tokens resolved to AppKit values. Replaced wholesale when theme.json changes.
@MainActor
struct Style {
    let theme: Theme

    let base: NSColor, sidebar: NSColor, raised: NSColor, selected: NSColor
    let primary: NSColor, secondary: NSColor, muted: NSColor
    let accent: NSColor, ok: NSColor, warn: NSColor, danger: NSColor, dangerStrong: NSColor
    let border: NSColor
    let ui: NSFont, uiSmall: NSFont, mono: NSFont, monoSmall: NSFont, monoLarge: NSFont

    var navBar: CGFloat { theme.metrics.navBar }
    var row: CGFloat { theme.metrics.row }
    var indent: CGFloat { theme.metrics.indent }
    var glyph: CGFloat { theme.metrics.glyph }

    init(_ theme: Theme) {
        self.theme = theme
        let c = theme.color
        base = Style.color(c.bg.base); sidebar = Style.color(c.bg.sidebar)
        raised = Style.color(c.bg.raised); selected = Style.color(c.bg.selected)
        primary = Style.color(c.fg.primary); secondary = Style.color(c.fg.secondary); muted = Style.color(c.fg.muted)
        accent = Style.color(c.accent)
        ok = Style.color(c.ok); warn = Style.color(c.warn); danger = Style.color(c.danger)
        dangerStrong = Style.color(c.dangerStrong); border = Style.color(c.resolvedBorder)
        let size = CGFloat(theme.font.size)
        func uiFont(_ s: CGFloat) -> NSFont {
            theme.font.ui == "system" ? .systemFont(ofSize: s) : (NSFont(name: theme.font.ui, size: s) ?? .systemFont(ofSize: s))
        }
        func monoFont(_ s: CGFloat) -> NSFont {
            NSFont(name: theme.font.mono, size: s) ?? .monospacedSystemFont(ofSize: s, weight: .regular)
        }
        ui = uiFont(size); uiSmall = uiFont(size - 1)
        mono = monoFont(size); monoSmall = monoFont(size - 1); monoLarge = monoFont(size + 1)
    }

    static func color(_ hex: String) -> NSColor {
        guard let c = parseHexColor(hex) else { return .magenta }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    func workspaceColor(_ hex: String) -> NSColor { Style.color(hex) }

    /// A 14pt glyph image: SF Symbol by default, tinted by the caller. Shared per name, size and
    /// weight, so views that set the same glyph again see the same image and don't redraw.
    func symbol(_ name: String, size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSImage? {
        let pointSize = size ?? glyph - 2
        let key = "\(name)|\(pointSize)|\(weight.rawValue)"
        if let hit = Style.symbols[key] { return hit }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        Style.symbols[key] = image
        return image
    }
    private static var symbols: [String: NSImage?] = [:]
}

/// WCAG contrast of two drawn colours (1…21; alpha ignored).
func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
    return contrastRatio(hex(a), hex(b)) ?? 21
}

/// A flat view with a solid background and optional hairlines. No layers tricks, no vibrancy.
class FlatView: NSView {
    var fill: NSColor? { didSet { if fill != oldValue { needsDisplay = true } } }
    var borderColor: NSColor? { didSet { if borderColor != oldValue { needsDisplay = true } } }
    var edges: NSRectEdge.Set = [] { didSet { if edges != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let fill { fill.setFill(); bounds.fill() }
        guard let borderColor, !edges.isEmpty else { return }
        borderColor.setFill()
        if edges.contains(.top) { NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
        if edges.contains(.bottom) { NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
        if edges.contains(.left) { NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill() }
        if edges.contains(.right) { NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
    }
}

extension NSRectEdge {
    struct Set: OptionSet {
        let rawValue: Int
        static let top = Set(rawValue: 1), bottom = Set(rawValue: 2), left = Set(rawValue: 4), right = Set(rawValue: 8)
        static let all: Set = [.top, .bottom, .left, .right]
    }
}

/// A square glyph button: no bezel, hover fill, tinted symbol or text.
final class GlyphButton: NSView {
    var action: (() -> Void)?
    var image: NSImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    var text: String? { didSet { if text != oldValue { needsDisplay = true } } }
    var tint: NSColor = .white { didSet { if tint != oldValue { needsDisplay = true } } }
    var hoverFill: NSColor = .darkGray
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    var font: NSFont = .systemFont(ofSize: 12)
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    /// The last tinted glyph: NSImage keeps its rendering, so redraws (hover) don't re-render the symbol.
    private var tinted: (source: NSImage, color: NSColor, image: NSImage)?

    override var isFlipped: Bool { true }

    /// Laid out with frames by the owner; `size` is just the initial frame.
    init(size: CGFloat = 24, width: CGFloat? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: width ?? size, height: size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if isEnabled { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside, isEnabled { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, hovering || pressed { (pressed ? hoverFill.blended(withFraction: 0.3, of: .white) ?? hoverFill : hoverFill).setFill(); bounds.fill() }
        let color = isEnabled ? tint : tint.withAlphaComponent(0.35)
        if let image {
            let tinted: NSImage
            if let t = self.tinted, t.source === image, t.color == color { tinted = t.image } else {
                tinted = image.tinted(color)
                self.tinted = (image, color, tinted)
            }
            let s = tinted.size
            tinted.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        } else if let text {
            // Centre the glyph's ink, not its line box: symbol glyphs from fallback fonts
            // have ascent/descent that would otherwise push them off centre.
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(string), .useGlyphPathBounds)
            // Flipped view: without .usesLineFragmentOrigin the rect origin is the baseline.
            let scale = window?.backingScaleFactor ?? 2, px = { (v: CGFloat) in (v * scale).rounded() / scale }
            string.draw(with: NSRect(x: px(bounds.width / 2 - ink.midX), y: px(bounds.height / 2 + ink.midY),
                                     width: bounds.width, height: 0), options: [])
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    /// VoiceOver's name is the tooltip without its shortcut ("Back (⌘[)" reads "Back"); the tooltip stays the help.
    override func accessibilityLabel() -> String? {
        if let set = super.accessibilityLabel(), !set.isEmpty { return set }
        guard let tip = toolTip else { return text }
        return tip.range(of: " (", options: .backwards).map { String(tip[..<$0.lowerBound]) } ?? tip
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        action()
        return true
    }
}

/// VoiceOver's handle on one hand-drawn item (palette suggestions, login picker, sidebar strips); "press" picks it.
final class PressableElement: NSAccessibilityElement {
    var press: () -> Bool = { false }

    convenience init(_ role: NSAccessibility.Role, _ label: String, in parent: NSView, selected: Bool = false) {
        self.init()
        setAccessibilityElement(true)
        setAccessibilityRole(role)
        setAccessibilityLabel(label)
        setAccessibilityParent(parent)
        setAccessibilitySelected(selected)
    }

    /// `r` is in the parent's own coordinates. AX parent space is bottom-up even for a flipped view:
    /// unflipped, VoiceOver's cursor lands on the mirrored item.
    @MainActor func place(_ r: NSRect, in parent: NSView) {
        var r = r
        if parent.isFlipped { r.origin.y = parent.bounds.height - r.maxY }
        setAccessibilityFrameInParentSpace(r)
    }

    override func accessibilityPerformPress() -> Bool { press() }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return img
    }
}

/// Plain label factory.
@MainActor
func label(_ text: String = "", font: NSFont, color: NSColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}
