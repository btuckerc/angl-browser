import AnglCore
import AppKit

/// Theme tokens resolved to AppKit values. Replaced wholesale when theme.json changes.
@MainActor
struct Style {
    let theme: Theme
    /// Active Liquid Glass on floating panels (macOS 26+, enabled in theme, and neither Reduce Transparency nor Increase Contrast active).
    let glass: Bool

    let base: NSColor, sidebar: NSColor, raised: NSColor, selected: NSColor
    let primary: NSColor, secondary: NSColor, muted: NSColor
    let accent: NSColor, ok: NSColor, warn: NSColor, danger: NSColor, dangerStrong: NSColor
    let border: NSColor
    let ui: NSFont, uiSmall: NSFont, mono: NSFont, monoSmall: NSFont, monoLarge: NSFont

    var navBar: CGFloat { theme.metrics.navBar }
    var row: CGFloat { theme.metrics.row }
    var indent: CGFloat { theme.metrics.indent }
    var glyph: CGFloat { theme.metrics.glyph }
    var radius: CGFloat { max(0, CGFloat(theme.radius)) }
    var smallRadius: CGFloat { radius > 0 ? min(radius, 5) : 0 }
    var tinyRadius: CGFloat { radius > 0 ? min(radius, 3) : 0 }

    init(_ theme: Theme, glass: Bool = false) {
        self.theme = theme
        self.glass = glass
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

    /// `symbol` tinted, shared per glyph and color: a redraw reuses one image and its cached
    /// raster instead of re-rendering the vector glyph through a fresh drawing handler. Dropped
    /// when the browser's style changes, so live theme edits don't accumulate them.
    func symbol(_ name: String, size: CGFloat? = nil, weight: NSFont.Weight = .regular, tint: NSColor) -> NSImage? {
        let key = TintKey(name: name, size: size ?? glyph - 2, weight: weight.rawValue, color: tint)
        if let hit = Style.tinted[key] { return hit }
        let image = symbol(name, size: size, weight: weight)?.tinted(tint)
        Style.tinted[key] = image
        return image
    }
    private struct TintKey: Hashable { let name: String, size: CGFloat, weight: CGFloat, color: NSColor }
    private static var tinted: [TintKey: NSImage?] = [:]
    static func dropTintedSymbols() { tinted.removeAll() }
}

/// WCAG contrast of `a` drawn over the opaque `b` (1…21): a translucent `a` is blended into `b` first.
func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), byte(c.alphaComponent))
    }
    return contrastRatio(hex(a), hex(b)) ?? 21
}

/// A flat view with a solid background, optional corner radius and optional hairlines. Solid fills
/// and all-edge hairlines paint through CALayer properties (zero IOSurface backing store); partial
/// edges draw on demand.
class FlatView: NSView {
    var fill: NSColor? { didSet { if fill != oldValue { needsDisplay = true } } }
    var borderColor: NSColor? { didSet { if borderColor != oldValue { syncBacking(); needsDisplay = true } } }
    var edges: NSRectEdge.Set = [] { didSet { if edges != oldValue { syncBacking(); needsDisplay = true } } }
    var cornerRadius: CGFloat = 0 { didSet { if cornerRadius != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { edges.isEmpty || borderColor == nil || edges == .all }

    private func syncBacking() {
        if wantsUpdateLayer { layer?.contents = nil }
    }

    override func layout() {
        super.layout()
        if wantsUpdateLayer, cornerRadius > 0 {
            layer?.cornerRadius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill?.cgColor
            layer?.cornerRadius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
            if edges == .all, let borderColor {
                layer?.borderWidth = 1
                layer?.borderColor = borderColor.cgColor
            } else {
                layer?.borderWidth = 0
                layer?.borderColor = nil
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = nil
        layer?.cornerRadius = 0
        layer?.borderWidth = 0
        layer?.borderColor = nil
        let r = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        if let fill {
            fill.setFill()
            if r > 0 { NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill() } else { bounds.fill() }
        }
        guard let borderColor, !edges.isEmpty else { return }
        if r > 0, edges == .all {
            borderColor.setStroke()
            let sr = max(0, r - 0.5)
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: sr, yRadius: sr)
            p.lineWidth = 1
            p.stroke()
            return
        }
        borderColor.setFill()
        if edges.contains(.top) { NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
        if edges.contains(.bottom) { NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
        if edges.contains(.left) { NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill() }
        if edges.contains(.right) { NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
    }
}

/// Decorative FlatView that passes all pointer hit-testing through to views behind/around it.
final class PassiveFlatView: FlatView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hosts a floating panel's `body` in an `NSGlassEffectView` when Liquid Glass is active,
/// or directly as `panel.contentView` when solid. Safe to call repeatedly on live theme changes.
@MainActor
func applyPanelSurface(_ panel: NSPanel, body: NSView, style: Style) {
    let transparent = style.glass || style.radius > 0
    panel.isOpaque = !transparent
    panel.backgroundColor = transparent ? .clear : style.raised
    if #available(macOS 26.0, *), style.glass {
        let glass = (panel.contentView as? NSGlassEffectView) ?? NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = style.radius
        glass.tintColor = style.raised.withAlphaComponent(0.84)
        body.autoresizingMask = [.width, .height]
        if glass.contentView !== body {
            body.removeFromSuperview()
            glass.contentView = body
        }
        if panel.contentView !== glass { panel.contentView = glass }
        body.frame = glass.bounds
    } else {
        if #available(macOS 26.0, *), let glass = panel.contentView as? NSGlassEffectView {
            glass.contentView = nil
        }
        body.autoresizingMask = [.width, .height]
        if panel.contentView !== body {
            body.removeFromSuperview()
            panel.contentView = body
        }
    }
    panel.invalidateShadow()
}

/// Fills a row pill (`smallRadius` inset horizontally when rounded, full-bleed when sharp),
/// clipping an optional 2 pt leading accent bar cleanly inside the pill.
func fillRowPill(_ rect: NSRect, fill: NSColor?, bar: NSColor?, radius: CGFloat) {
    let r = radius > 0 ? rect.insetBy(dx: 5, dy: 1) : rect
    let cr = radius > 0 ? min(radius, min(r.width, r.height) / 2) : 0
    if cr > 0 {
        let path = NSBezierPath(roundedRect: r, xRadius: cr, yRadius: cr)
        if let fill { fill.setFill(); path.fill() }
        if let bar {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            bar.setFill()
            NSRect(x: r.minX, y: r.minY, width: 2, height: r.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    } else {
        if let fill { fill.setFill(); r.fill() }
        if let bar { bar.setFill(); NSRect(x: r.minX, y: r.minY, width: 2, height: r.height).fill() }
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
    var cornerRadius: CGFloat = 0 { didSet { if cornerRadius != oldValue { needsDisplay = true } } }
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
        if isEnabled, hovering || pressed {
            (pressed ? hoverFill.blended(withFraction: 0.3, of: .white) ?? hoverFill : hoverFill).setFill()
            let r = min(cornerRadius, min(bounds.width, bounds.height) / 2)
            if r > 0 { NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill() } else { bounds.fill() }
        }
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
