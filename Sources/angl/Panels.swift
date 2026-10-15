import AnglCore
import AppKit
import WebKit

// MARK: - New-tab surface

/// A blank tab is not a web view. In palette mode it holds the address field, docked, with the wordmark
/// as its prompt and the wordmark's ▮ as its caret; otherwise (or with `window.newTab: mark`) just the
/// wordmark. Until the first navigation ever, a hint sits underneath.
final class BlankView: FlatView {
    private unowned let owner: BrowserWindowController
    private let mark = NSTextField(labelWithString: "angl")
    private let hint = NSTextField(labelWithString: "⌘L go · ⌘K commands · ⌘, settings")
    private let dock: PaletteView

    init(owner: BrowserWindowController) {
        self.owner = owner
        dock = PaletteView(owner: owner, docked: true)
        super.init(frame: .zero)
        mark.alignment = .center
        hint.alignment = .center
        addSubview(mark)
        addSubview(hint)
        addSubview(dock)
        dock.onResize = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var docked: Bool { owner.paletteMode && owner.browser.theme.window.newTab == .field }

    /// ⌘T / ⌘L / ⌘K on an empty tab: the docked field, refilled.
    func focusField(prefill: String?) {
        dock.load(prefill: prefill, newTab: owner.active == nil)
        dock.focus()
    }

    /// Back to the docked field, keeping whatever was typed.
    func takeKeyboard() {
        guard docked else { return }
        dock.newTab = owner.active == nil
        if !dock.editing { dock.focus() }
    }

    func bookmarksChanged() { if docked { dock.bookmarksChanged() } }
    var holdsKeyboard: Bool { dock.editing }

    func applyStyle(_ s: Style) {
        fill = s.base
        // Docked, `angl` is right-aligned against the field: a label sized to its own text drops the last glyph.
        let para = NSMutableParagraphStyle()
        para.alignment = docked ? .right : .center // attributed values ignore the field's own alignment
        let wordmark = NSMutableAttributedString(string: "angl", attributes: [.font: s.monoLarge, .foregroundColor: s.muted, .paragraphStyle: para])
        // Docked, the ▮ is the field's caret instead.
        if !docked { wordmark.append(NSAttributedString(string: " ▮", attributes: [.font: s.monoLarge, .foregroundColor: s.accent, .paragraphStyle: para])) }
        mark.attributedStringValue = wordmark
        hint.font = s.monoSmall
        hint.textColor = s.muted
        dock.isHidden = !docked
        if !docked, dock.editing { window?.makeFirstResponder(nil) }
        dock.applyStyle()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hint.isHidden = UserDefaults.standard.bool(forKey: "angl.hintSeen")
        let hh = ceil(hint.intrinsicContentSize.height)
        guard docked else {
            let mh = ceil(mark.intrinsicContentSize.height)
            mark.frame = NSRect(x: 0, y: bounds.midY - mh, width: bounds.width, height: mh)
            hint.frame = NSRect(x: 0, y: mark.frame.maxY + 8, width: bounds.width, height: hh)
            return
        }
        // `angl` then the field, as one centred row lifted above the middle (dead centre reads low).
        // The row stays put while suggestions grow under it, so it is placed for the longest list.
        let band = PaletteView.fieldBand
        let markW = ceil(("angl" as NSString).size(withAttributes: [.font: owner.style.monoLarge]).width)
        let gap = ceil(("  " as NSString).size(withAttributes: [.font: owner.style.monoLarge]).width)
        let width = max(120, min(640, bounds.width - 64 - markW - gap))
        let longest = band + CGFloat(Suggestions.limit) * SuggestionList.rowHeight + 2
        let top = max(8, min(bounds.midY - 60 - band / 2, bounds.height - longest - 8)).rounded()
        let x = ((bounds.width - markW - gap - width) / 2).rounded()
        dock.frame = NSRect(x: x + markW + gap, y: top, width: width, height: dock.height)
        // Same font and frame as the field's text, so `angl` shares its baseline.
        let font = owner.style.monoLarge
        let fh = ceil(font.ascender - font.descender + font.leading) + 2
        mark.frame = NSRect(x: 0, y: top + 1 + ((band - fh) / 2).rounded(), width: max(0, dock.frame.minX - gap + 3), height: fh)
        hint.frame = NSRect(x: 0, y: top + band + 2 + 8, width: bounds.width, height: hh)
    }

    override func mouseDown(with event: NSEvent) {
        if docked { takeKeyboard() } else { owner.focusURLField() }
    }
}

// MARK: - Status line and toasts

/// Bottom-left overlay: hovered link (mono, middle-truncated) or a short coloured toast.
final class StatusOverlay: FlatView {
    private let text = NSTextField(labelWithString: "")
    private var hover: String?
    private var toast: (String, NSColor)?
    private var toastTimer: Timer?
    private var style: Style?
    private var area = NSRect.zero

    init() {
        super.init(frame: .zero)
        text.lineBreakMode = .byTruncatingMiddle
        addSubview(text)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyStyle(_ s: Style) {
        style = s
        fill = s.base
        borderColor = s.border
        edges = [.top, .right]
        text.font = s.monoSmall
        render()
    }

    func show(_ link: String?, from tab: Tab) {
        hover = link
        render()
    }

    func flash(_ message: String, color: NSColor) {
        toast = (message, color)
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.toast = nil; self?.render() }
        }
        render()
    }

    func reposition(in bounds: NSRect) {
        area = bounds
        render()
    }

    private func render() {
        guard let s = style else { return }
        let (msg, color): (String?, NSColor) = toast.map { ($0.0, $0.1) } ?? (hover, s.secondary)
        guard let msg, !msg.isEmpty else { isHidden = true; return }
        isHidden = false
        text.stringValue = msg
        text.textColor = color
        // cellSize includes the label's text padding; intrinsicContentSize doesn't, which clipped short toasts.
        let w = min(ceil(text.cell?.cellSize.width ?? text.intrinsicContentSize.width) + 16, area.width * 0.6)
        frame = NSRect(x: area.minX, y: area.maxY - 20, width: w, height: 20)
        let th = ceil(text.intrinsicContentSize.height)
        text.frame = NSRect(x: 8, y: (20 - th) / 2 + 1, width: w - 16, height: th)
    }
}

// MARK: - Inline permission / question bar

/// 28 px strip under the nav bar: a question and a few buttons. One question at a time.
final class PermissionBar: FlatView {
    private let text = NSTextField(labelWithString: "")
    private var buttons: [GlyphButton] = []
    private var style: Style?
    private var pending: CheckedContinuation<Int, Never>?
    private var queue: [(String, [String], CheckedContinuation<Int, Never>)] = []
    private weak var owner: BrowserWindowController?

    init() {
        super.init(frame: .zero)
        text.lineBreakMode = .byTruncatingTail
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyStyle(_ s: Style) {
        style = s
        fill = s.raised
        borderColor = s.border
        edges = .bottom
        text.font = s.ui
        text.textColor = s.primary
    }

    /// Returns the index of the button pressed.
    func ask(_ question: String, buttons titles: [String], owner: BrowserWindowController) async -> Int {
        self.owner = owner
        return await withCheckedContinuation { c in
            queue.append((question, titles, c))
            if pending == nil { next() }
        }
    }

    private func next() {
        guard !queue.isEmpty, let s = style else {
            isHidden = true
            owner?.layoutStrips()
            return
        }
        let (q, titles, c) = queue.removeFirst()
        pending = c
        text.stringValue = q
        buttons.forEach { $0.removeFromSuperview() }
        buttons = titles.enumerated().map { i, t in
            let w = ceil((t as NSString).size(withAttributes: [.font: s.ui]).width) + 20
            let b = GlyphButton(size: 22, width: w)
            b.text = t
            b.font = s.ui
            b.tint = i == titles.count - 1 ? s.secondary : s.accent
            b.hoverFill = s.selected
            b.action = { [weak self] in self?.answer(i) }
            addSubview(b)
            return b
        }
        isHidden = false
        needsLayout = true
        owner?.layoutStrips()
    }

    private func answer(_ i: Int) {
        let c = pending
        pending = nil
        c?.resume(returning: i)
        next()
    }

    override func layout() {
        super.layout()
        var x = bounds.width - 8
        for b in buttons.reversed() {
            x -= b.frame.width
            b.frame.origin = NSPoint(x: x, y: (bounds.height - b.frame.height) / 2)
            x -= 6
        }
        let th = ceil(text.intrinsicContentSize.height)
        text.frame = NSRect(x: 10, y: (bounds.height - th) / 2, width: max(0, x - 16), height: th)
    }
}

// MARK: - Find bar

final class FindBar: FlatView, NSTextFieldDelegate {
    unowned let owner: BrowserWindowController
    private let field = NSTextField()
    private let result = NSTextField(labelWithString: "")
    private let prev = GlyphButton(size: 22)
    private let next = GlyphButton(size: 22)
    private let caseButton = GlyphButton(size: 22, width: 28)
    private let close = GlyphButton(size: 22)
    private var caseSensitive = false

    init(owner: BrowserWindowController) {
        self.owner = owner
        super.init(frame: .zero)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.delegate = self
        field.placeholderString = "find in page"
        field.usesSingleLineMode = true
        for v: NSView in [field, result, prev, next, caseButton, close] { addSubview(v) }
        prev.action = { [weak self] in self?.find(backwards: true) }
        next.action = { [weak self] in self?.find(backwards: false) }
        caseButton.text = "Aa"
        caseButton.toolTip = "Match case"
        caseButton.action = { [weak self] in
            guard let self else { return }
            self.caseSensitive.toggle()
            self.applyStyle()
            self.find(backwards: false)
        }
        close.action = { [weak owner] in owner?.hideFind() }
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyStyle() {
        let s = owner.style
        fill = s.raised
        borderColor = s.border
        edges = .bottom
        field.font = s.mono
        field.textColor = s.primary
        field.backgroundColor = s.base
        result.font = s.monoSmall
        result.textColor = s.danger
        prev.image = s.symbol("chevron.up")
        next.image = s.symbol("chevron.down")
        close.image = s.symbol("xmark")
        caseButton.font = s.monoSmall
        caseButton.tint = caseSensitive ? s.accent : s.secondary
        for b in [prev, next, close] { b.tint = s.secondary }
        for b in [prev, next, close, caseButton] { b.hoverFill = s.selected }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let fh = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: 8, y: (h - fh) / 2, width: min(320, bounds.width / 2), height: fh)
        var x = field.frame.maxX + 6
        for b in [prev, next, caseButton] {
            b.frame.origin = NSPoint(x: x, y: (h - 22) / 2)
            x += b.frame.width + 2
        }
        let rh = ceil(result.intrinsicContentSize.height)
        result.frame = NSRect(x: x + 8, y: (h - rh) / 2, width: 120, height: rh)
        close.frame.origin = NSPoint(x: bounds.width - 30, y: (h - 22) / 2)
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ obj: Notification) { find(backwards: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            owner.hideFind()
            return true
        default:
            return false
        }
    }

    func find(backwards: Bool) {
        guard let wv = owner.active?.webView else { return }
        let text = field.stringValue
        guard !text.isEmpty else { result.stringValue = ""; return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.caseSensitive = caseSensitive
        cfg.wraps = true
        wv.find(text, configuration: cfg) { [weak self] r in
            MainActor.assumeIsolated { self?.result.stringValue = r.matchFound ? "" : "no matches" }
        }
    }
}

// MARK: - Site panel

/// Per-site controls under the gear: JS, blocker, fonts, square, dark, volume, zoom, container,
/// open in, permissions, clear data.
final class SitePanel: NSPanel, NSWindowDelegate {
    unowned let owner: BrowserWindowController
    let siteTab: Tab
    private let body = FlatView()
    private var rows: [NSView] = []
    private let width: CGFloat = 280
    private let rowH: CGFloat = 28

    init(owner: BrowserWindowController, tab: Tab) {
        self.owner = owner
        siteTab = tab
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        hasShadow = true
        level = .popUpMenu
        delegate = self
        contentView = body
    }

    override var canBecomeKey: Bool { true }

    func windowDidResignKey(_ notification: Notification) { close() }

    override func cancelOperation(_ sender: Any?) { close() }

    func show(below anchor: NSRect) {
        rebuild()
        let h = body.frame.height
        // Right-aligned under the anchor, but kept inside the window (the palette-mode gear sits near
        // the sidebar's right edge, so a right-aligned panel would hang off the window's left side).
        let bounds = owner.window?.frame ?? .infinite
        let x = min(max(anchor.maxX - width, bounds.minX + 4), bounds.maxX - width - 4)
        setFrame(NSRect(x: x, y: anchor.minY - h - 4, width: width, height: h), display: true)
        owner.window?.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        parent?.removeChildWindow(self)
        super.close()
    }

    private var url: URL? { siteTab.url }
    private var style: Style { owner.style }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        let s = style
        body.fill = s.raised
        body.borderColor = s.border
        body.edges = .all
        guard let url, let host = SiteStore.key(for: url) else { return }
        let b = Browser.shared!
        let p = b.policy(for: url)
        let o = b.sites.sites[host]
        let c = siteTab.container

        addRow(text: host, font: s.mono, color: s.primary)
        let containerLine = "container: \(c.name)" + (c.proxy.map { " · proxy: \($0.host):\($0.port)" } ?? "")
        addRow(text: containerLine, font: s.monoSmall, color: s.secondary)
        addSeparator()
        addToggle("JavaScript", on: p.javascript, overridden: o?.javascript != nil) { o, p in o.javascript = !p.javascript }
        addToggle("Blocker", on: p.blocker, overridden: o?.blocker != nil, detail: "\(b.web.blocker.ruleCount) rules") { o, p in
            o.blocker = !p.blocker
        }
        addToggle("Block remote fonts", on: p.blockRemoteFonts, overridden: o?.blockRemoteFonts != nil) { o, p in
            o.blockRemoteFonts = !p.blockRemoteFonts
        }
        addToggle("Square corners", on: p.square, overridden: o?.square != nil) { o, p in o.square = !p.square }
        addChoice("Dark", options: DarkMode.allCases.map(\.rawValue), selected: p.dark.rawValue) { [weak self] v in
            self?.change(reload: true) { o, _ in o.dark = DarkMode(rawValue: v) }
        }
        addChoice("Hardening", options: Hardening.allCases.map(\.rawValue), selected: p.hardening.rawValue) { [weak self] v in
            self?.change(reload: true) { o, _ in o.hardening = Hardening(rawValue: v) }
        }
        addVolume(p.volumeDB)
        addZoom(p.zoom)
        addSeparator()
        let containers = b.workspaces.containers
        addMenu("Container", options: ["Use Space default"] + containers.map(\.name),
                selected: siteTab.node.containerID.flatMap { id in containers.first(where: { $0.id == id })?.name } ?? "Use Space default") { [weak self] name in
            guard let self else { return }
            let target = name == "Use Space default" ? nil : containers.first(where: { $0.name == name })?.id
            guard name == "Use Space default" || target != nil else { return }
            self.owner.move(self.siteTab, toContainer: target)
            self.close()
        }
        let engines = Handoff.installed
        if !engines.isEmpty {
            addMenu("Open in", options: engines.map(\.name), selected: nil, placeholder: "browser") { [weak self] name in
                guard let self, let e = engines.first(where: { $0.name == name }) else { return }
                self.owner.handoffActive(engine: e)
                self.close()
            }
        }
        if p.camera != nil || p.microphone != nil {
            func word(_ v: Bool?) -> String { v.map { $0 ? "allow" : "block" } ?? "ask" }
            addButtonRow("camera \(word(p.camera)) · mic \(word(p.microphone))", button: "reset") { [weak self] in
                self?.change(reload: false) { o, _ in o.camera = nil; o.microphone = nil }
            }
        }
        addSeparator()
        addButtonRow("", button: "Clear site data", color: s.dangerStrong) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await Browser.shared.web.clearSiteData(host: host, in: self.siteTab.container)
                self.owner.toast("cleared \(host) data in \(self.siteTab.container.name)", color: self.style.danger)
                self.siteTab.reload(fromOrigin: true)
            }
            self.close()
        }
        if o != nil {
            addButtonRow("", button: "Reset site to defaults", color: s.secondary) { [weak self] in
                guard let self else { return }
                var st = Browser.shared.sites
                st.sites[host] = nil
                Browser.shared.setSites(st)
                self.siteTab.reload(fromOrigin: false)
                self.rebuild()
            }
        }
        layoutRows()
    }

    private func change(reload: Bool, _ f: (inout SiteOverrides, SitePolicy) -> Void) {
        owner.changeSite(reload: reload) { p, o in f(&o, p) }
        rebuild()
        if let anchor = Optional(frame) { setFrame(NSRect(x: anchor.minX, y: anchor.maxY - body.frame.height, width: width, height: body.frame.height), display: true) }
    }

    // Row builders

    private func addRow(text: String, font: NSFont, color: NSColor) {
        let l = label(text, font: font, color: color)
        l.translatesAutoresizingMaskIntoConstraints = true
        l.frame.size.height = 20
        rows.append(l)
    }

    private func addSeparator() {
        let v = FlatView()
        v.fill = style.border
        v.frame.size.height = 1
        rows.append(v)
    }

    private func addToggle(_ title: String, on: Bool, overridden: Bool, detail: String? = nil,
                           _ f: @escaping (inout SiteOverrides, SitePolicy) -> Void) {
        let row = PanelRow(style: style, title: title, detail: overridden ? "site" : detail)
        let box = ToggleSquare(style: style, on: on)
        box.action = { [weak self] in self?.change(reload: true, f) }
        row.accessory = box
        row.onClick = box.action
        rows.append(row)
    }

    private func addChoice(_ title: String, options: [String], selected: String?, _ pick: @escaping (String) -> Void) {
        let row = PanelRow(style: style, title: title, detail: nil)
        let seg = Segments(style: style, options: options, selected: selected, pick: pick)
        row.accessory = seg
        rows.append(row)
    }

    /// Open-ended, user-defined lists (containers, installed browsers) get a dropdown; segments
    /// are reserved for short fixed enums that always fit the row.
    private func addMenu(_ title: String, options: [String], selected: String?, placeholder: String = "choose",
                         _ pick: @escaping (String) -> Void) {
        let row = PanelRow(style: style, title: title, detail: nil)
        let drop = Dropdown(style: style, options: options, selected: selected, placeholder: placeholder, pick: pick)
        row.accessory = drop
        row.onClick = { [weak drop] in drop?.open() }
        rows.append(row)
    }

    private func addVolume(_ db: Double) {
        let row = PanelRow(style: style, title: "Volume", detail: siteTab.muted ? "muted" : db == 0 ? "0 dB" : String(format: "%.0f dB", db))
        let slider = NSSlider(value: db, minValue: -30, maxValue: 0, target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.frame.size = NSSize(width: 110, height: 20)
        let target = SliderTarget { [weak self, weak row] v in
            guard let self, let url = self.url else { return }
            let rounded = v.rounded()
            Browser.shared.updateSite(url) { $0.volumeDB = rounded == 0 ? nil : rounded }
            self.siteTab.invalidatePolicy()
            self.siteTab.applyVolume()
            row?.detail = rounded == 0 ? "0 dB" : String(format: "%.0f dB", rounded)
        }
        slider.target = target
        slider.action = #selector(SliderTarget.changed(_:))
        objc_setAssociatedObject(slider, "target", target, .OBJC_ASSOCIATION_RETAIN)
        row.accessory = slider
        rows.append(row)
        let mute = PanelRow(style: style, title: "Mute tab", detail: "⇧⌘M")
        let box = ToggleSquare(style: style, on: siteTab.muted)
        box.action = { [weak self] in self?.siteTab.toggleMute(); self?.rebuild() }
        mute.accessory = box
        mute.onClick = box.action
        rows.append(mute)
    }

    private func addZoom(_ zoom: Double) {
        let current = siteTab.webView.map { Double($0.pageZoom) } ?? zoom
        let row = PanelRow(style: style, title: "Zoom", detail: "\(Int((current * 100).rounded()))%")
        let seg = Segments(style: style, options: ["−", "100%", "+"], selected: nil) { [weak self] v in
            guard let self else { return }
            self.owner.zoom(by: v == "−" ? -0.1 : v == "+" ? 0.1 : nil)
            self.rebuild()
        }
        row.accessory = seg
        rows.append(row)
    }

    private func addButtonRow(_ title: String, button: String, color: NSColor? = nil, _ action: @escaping () -> Void) {
        let row = PanelRow(style: style, title: title, detail: nil)
        let w = ceil((button as NSString).size(withAttributes: [.font: style.ui]).width) + 16
        let b = GlyphButton(size: 22, width: w)
        b.text = button
        b.font = style.ui
        b.tint = color ?? style.accent
        b.hoverFill = style.selected
        b.action = action
        row.accessory = b
        rows.append(row)
    }

    private func layoutRows() {
        var y: CGFloat = 6
        body.subviews.forEach { $0.removeFromSuperview() }
        for r in rows {
            let h: CGFloat = r is FlatView && !(r is PanelRow) ? 1 : (r is NSTextField ? 20 : rowH)
            if h == 1 { y += 4 }
            r.frame = NSRect(x: r is NSTextField ? 12 : (h == 1 ? 0 : 0), y: y, width: r is NSTextField ? width - 24 : width, height: h)
            body.addSubview(r)
            y += h
            if h == 1 { y += 4 }
        }
        body.frame = NSRect(x: 0, y: 0, width: width, height: y + 6)
    }
}

@MainActor
private final class SliderTarget: NSObject {
    let f: (Double) -> Void
    init(_ f: @escaping (Double) -> Void) { self.f = f }
    @objc func changed(_ s: NSSlider) { f(s.doubleValue) }
}

/// 28 px row: title, optional muted detail, accessory on the right.
final class PanelRow: FlatView {
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    var accessory: NSView? {
        didSet { oldValue?.removeFromSuperview(); accessory.map(addSubview); needsLayout = true }
    }
    var detail: String? { didSet { detailLabel.stringValue = detail ?? "" } }
    var onClick: (() -> Void)?

    init(style s: Style, title: String, detail: String?) {
        titleLabel = label(title, font: s.ui, color: s.primary)
        detailLabel = label(detail ?? "", font: s.monoSmall, color: s.muted)
        super.init(frame: .zero)
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(titleLabel)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        var right = bounds.width - 12
        if let a = accessory {
            a.frame.origin = NSPoint(x: right - a.frame.width, y: (h - a.frame.height) / 2)
            right = a.frame.minX - 8
        }
        // Measured from the string, not intrinsicContentSize (which came back short inside the panel).
        let tw = min(ceil(titleLabel.attributedStringValue.size().width) + 4, right - 12)
        let th = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = NSRect(x: 12, y: (h - th) / 2, width: tw, height: th)
        let dh = ceil(detailLabel.intrinsicContentSize.height)
        detailLabel.frame = NSRect(x: titleLabel.frame.maxX + 6, y: (h - dh) / 2 + 1, width: max(0, right - titleLabel.frame.maxX - 6), height: dh)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// 12×12 square toggle: filled accent = on.
final class ToggleSquare: NSView {
    let style: Style
    var on: Bool { didSet { needsDisplay = true } }
    var action: (() -> Void)?

    init(style: Style, on: Bool) {
        self.style = style
        self.on = on
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        if on { style.accent.setFill(); r.fill() }
        (on ? style.accent : style.muted).setStroke()
        let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()
    }

    override func mouseDown(with event: NSEvent) { action?() }
}

/// Row of square text options; the selected one is filled.
final class Segments: NSView {
    init(style s: Style, options: [String], selected: String?, pick: @escaping (String) -> Void) {
        super.init(frame: .zero)
        var x: CGFloat = 0
        for o in options {
            let w = ceil((o as NSString).size(withAttributes: [.font: s.monoSmall]).width) + 12
            let b = GlyphButton(size: 20, width: w)
            b.text = o
            b.font = s.monoSmall
            b.tint = o == selected ? s.base : s.secondary
            b.hoverFill = s.selected
            b.action = { pick(o) }
            b.frame.origin.x = x
            if o == selected {
                let bg = FlatView(frame: b.frame)
                bg.fill = s.accent
                addSubview(bg)
            }
            addSubview(b)
            x += w + 2
        }
        frame.size = NSSize(width: max(0, x - 2), height: 20)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

/// Flat bordered button showing the current value and ▾; click pops a native menu of options.
final class Dropdown: NSView {
    private let style: Style
    private let options: [String]
    private let selected: String?
    private let pick: (String) -> Void
    private let text: String
    private var hovering = false { didSet { needsDisplay = true } }
    private static let maxWidth: CGFloat = 150

    init(style s: Style, options: [String], selected: String?, placeholder: String, pick: @escaping (String) -> Void) {
        style = s
        self.options = options
        self.selected = selected
        self.pick = pick
        let attrs: [NSAttributedString.Key: Any] = [.font: s.monoSmall]
        let caret = " ▾"
        var t = selected ?? placeholder
        while t.count > 1, ((t + caret) as NSString).size(withAttributes: attrs).width > Self.maxWidth - 12 {
            t = String(t.dropLast(t.hasSuffix("…") ? 2 : 1)) + "…"
        }
        text = t + caret
        let w = ceil((text as NSString).size(withAttributes: attrs).width) + 12
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 20))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { open() }

    func open() {
        let menu = NSMenu()
        menu.font = style.monoSmall
        for o in options {
            menu.addItem(ClosureMenuItem(o, state: o == selected ? .on : .off) { [pick] in pick(o) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
        hovering = false
    }

    override func draw(_ dirtyRect: NSRect) {
        (hovering ? style.selected : style.raised).setFill()
        bounds.fill()
        style.border.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: style.monoSmall, .foregroundColor: selected == nil ? style.secondary : style.primary]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: 6, y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityValue() -> Any? { selected }
    override func accessibilityPerformPress() -> Bool { open(); return true }
}
