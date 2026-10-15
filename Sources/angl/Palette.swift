import AnglCore
import AppKit

/// The address field and its suggestion rows: floated over a page by `PalettePanel`, or docked in an
/// empty tab by `BlankView`. One delegate, one suggestion pipeline, one key handler for both.
@MainActor
final class PaletteView: FlatView, NSTextFieldDelegate {
    unowned let owner: BrowserWindowController
    let docked: Bool
    let field = URLTextField()
    private let list = SuggestionList()
    private var items: [Suggestion] = []
    private var selected = 0
    private(set) var tabChooser = false
    /// Commits open a new tab (⌘T, an empty Space) rather than navigating the current one.
    var newTab = false
    /// The floating panel closes on a commit or Esc; a docked field clears instead.
    var onClose: () -> Void = {}
    /// The rows changed; the host refits to `height`, keeping the field where it is.
    var onResize: () -> Void = {}
    private var caret: PromptCaret?

    /// Height of the input row; the text is centred in it whether or not suggestions follow.
    static let fieldBand: CGFloat = 44
    var height: CGFloat { Self.fieldBand + CGFloat(items.count) * SuggestionList.rowHeight + 2 }
    var editing: Bool { field.currentEditor() != nil }

    init(owner: BrowserWindowController, docked: Bool) {
        self.owner = owner
        self.docked = docked
        super.init(frame: .zero)
        edges = .all
        if docked { field.cell = PromptCell(textCell: "") }
        field.isEditable = true; field.isSelectable = true
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.usesSingleLineMode = true; field.cell?.isScrollable = true; field.cell?.wraps = false
        field.placeholderString = "search or address (> for commands)"; field.delegate = self
        addSubview(field); addSubview(list)
        list.onPick = { [weak self] i in self?.commitSuggestion(i) }
        if docked {
            let caret = PromptCaret(view: self)
            self.caret = caret
            field.onFocus = { [weak self] in self?.focusChanged() }
        }
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(prefill: String?, newTab: Bool) {
        tabChooser = false
        field.placeholderString = "search or address (> for commands)"
        self.newTab = newTab; field.stringValue = prefill ?? ""; refresh()
    }

    func loadTabChooser() {
        tabChooser = true
        newTab = false
        field.stringValue = ""
        field.placeholderString = "split with a tab in this Space"
        refresh()
    }

    /// Keyboard into the field with its text selected, so typing replaces a prefilled address.
    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func chooserItems(_ query: String) -> [Suggestion] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let nodes = owner.tree.allTabs.compactMap { node -> Suggestion? in
            guard node.id != owner.active?.node.id else { return nil }
            let title = owner.liveTab(node)?.displayTitle
                ?? (node.title.isEmpty ? node.url.map(Omnibox.display) ?? "New Tab" : node.title)
            let url = node.url.map(Omnibox.display) ?? ""
            let haystack = (title + " " + (node.url?.absoluteString ?? "")).lowercased()
            guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }
            return Suggestion(kind: .tab, title: title, detail: url, hint: "◫") { [weak self] _ in
                self?.close()
                self?.owner.split(with: node)
            }
        }
        return Array(nodes.prefix(12))
    }

    /// After a commit: the panel goes away; the docked field empties and stays where it is.
    private func close() {
        if docked { field.stringValue = ""; refresh() } else { onClose() }
    }

    /// Flipped: a 1 pt border, the input band, then the suggestion rows, then the border.
    override func layout() {
        super.layout()
        let font = field.font ?? owner.style.monoLarge
        let fh = ceil(font.ascender - font.descender + font.leading) + 2
        field.frame = NSRect(x: 16, y: 1 + ((Self.fieldBand - fh) / 2).rounded(), width: bounds.width - 32, height: fh)
        list.frame = NSRect(x: 1, y: 1 + Self.fieldBand, width: bounds.width - 2, height: max(0, bounds.height - Self.fieldBand - 2))
        list.isHidden = items.isEmpty
        caret?.update()
    }

    /// Bookmark edits from a row's context menu show up in the open list.
    func bookmarksChanged() { if !tabChooser { refresh() } }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func controlTextDidEndEditing(_ obj: Notification) { if docked { focusChanged() } }

    private func refresh() {
        items = tabChooser ? chooserItems(field.stringValue) : Suggestions.compute(field.stringValue, window: owner)
        selected = 0
        list.style = owner.style; list.items = items; list.selected = selected
        onResize()
        needsLayout = true
    }

    /// The docked border is the accent only while the field has the keyboard. Deferred: the field editor
    /// is still attached when the end-of-editing notification arrives.
    private func focusChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.borderColor = self.docked && !self.editing ? self.owner.style.border : self.owner.style.accent
        }
        caret?.update()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !items.isEmpty else { return true }
            selected = (selected + (selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1) + items.count) % items.count
            list.selected = selected
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if items.indices.contains(selected) {
                if tabChooser { items[selected].act(.current) } else { run(items[selected], disposition()) }
            } else if !tabChooser {
                OmniboxEditing.commit(field.stringValue, window: owner, disposition: disposition(), close: close)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Docked there is nothing to dismiss: Esc clears, then lets go of the keyboard.
            if !docked { onClose() } else if field.stringValue.isEmpty { window?.makeFirstResponder(nil) } else { close() }
            return true
        default: return false
        }
    }

    /// ⇧ new window, ⌘ child tab, else this field's own target (new tab for ⌘T, current tab for ⌘L).
    private func disposition() -> NavBar.Disposition {
        let f = NSApp.currentEvent?.modifierFlags ?? []
        return f.contains(.shift) ? .newWindow : f.contains(.command) ? .childTab : newTab ? .newTab : .current
    }

    private func commitSuggestion(_ i: Int) {
        if items.indices.contains(i) {
            if tabChooser { items[i].act(.current) } else { run(items[i], disposition()) }
        }
    }

    private func run(_ s: Suggestion, _ d: NavBar.Disposition) {
        OmniboxEditing.run(s, disposition: d, close: close)
    }

    func applyStyle() {
        let s = owner.style
        fill = s.raised
        field.font = s.monoLarge; field.textColor = s.primary
        (field.cell as? PromptCell)?.prompt = docked && owner.browser.theme.window.caret == .block ? s : nil
        caret?.color = s.accent
        focusChanged()
        refresh()
    }
}

@MainActor
final class PalettePanel: NSPanel {
    unowned let owner: BrowserWindowController
    private let view: PaletteView

    init(owner: BrowserWindowController) {
        self.owner = owner
        view = PaletteView(owner: owner, docked: false)
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = true; backgroundColor = owner.style.raised; hasShadow = true; level = .floating
        isReleasedWhenClosed = false
        contentView = view
        view.onClose = { [weak self] in self?.closePalette() }
        view.onResize = { [weak self] in self?.fit() }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(prefill: String?, newTab: Bool) {
        view.load(prefill: prefill, newTab: newTab)
        present()
        view.field.currentEditor()?.selectAll(nil)
    }

    func showTabChooser() {
        guard owner.browser.settings.tabs.splitView, owner.active != nil else { return }
        view.loadTabChooser()
        present()
    }

    private func present() {
        guard let parent = owner.window else { return }
        let width = min(640, max(1, owner.content.bounds.width - 64))
        let height = view.height
        setContentSize(NSSize(width: width, height: height)); view.layoutSubtreeIfNeeded()
        let contentRect = owner.content.convert(owner.content.bounds, to: nil)
        let screenRect = parent.convertToScreen(contentRect)
        // Whole points: a fractional origin smears the 1 pt border on the top edge.
        setFrameOrigin(NSPoint(x: (screenRect.midX - width / 2).rounded(),
                               y: (screenRect.maxY - height - parent.frame.height * 0.18).rounded()))
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil); makeFirstResponder(view.field)
    }

    /// Grow downward from a fixed top edge so the input row never moves while typing.
    private func fit() {
        guard isVisible else { return }
        let h = view.height
        setFrame(NSRect(x: frame.minX, y: frame.maxY - h, width: frame.width, height: h), display: true)
    }

    func closePalette() {
        parent?.removeChildWindow(self); orderOut(nil); owner.focusContent()
    }
    @objc private func windowResigned() { if isVisible { closePalette() } }

    func bookmarksChanged() { if isVisible { view.bookmarksChanged() } }

    func applyStyle() {
        backgroundColor = owner.style.raised
        view.applyStyle()
    }
}

// MARK: - The docked field's caret

/// Hands the docked field its own field editor, so the system caret can be swapped for `PromptCaret`.
@MainActor
final class PromptCell: NSTextFieldCell {
    /// Set while the block caret is on; nil gives the window's shared editor and the system caret.
    var prompt: Style? { didSet { if prompt == nil { editor = nil } } }
    private var editor: PromptEditor?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard prompt != nil else { return super.fieldEditor(for: controlView) }
        if let editor { return editor }
        let e = PromptEditor(usingTextLayoutManager: false) // TextKit 1: glyph positions and temporary attributes
        e.isFieldEditor = true
        editor = e
        return e
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let t = super.setUpFieldEditorAttributes(textObj)
        if let e = t as? PromptEditor, let s = prompt {
            e.insertionPointColor = .clear
            // The system's accent selection block is the loudest thing on an empty page; a tint says it quietly.
            e.selectedTextAttributes = [.backgroundColor: s.primary.withAlphaComponent(0.12), .foregroundColor: s.primary]
        }
        return t
    }
}

/// A field editor that reports every caret move and hides the system insertion indicator.
final class PromptEditor: NSTextView {
    var onCaretMove: (() -> Void)?

    override var shouldDrawInsertionPoint: Bool { false }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        onCaretMove?()
    }

    override func didChangeText() {
        super.didChangeText()
        onCaretMove?()
    }

    /// The insertion point's x and baseline in this view; nil while text is selected.
    var insertion: NSPoint? {
        let sel = selectedRange()
        guard sel.length == 0, let lm = layoutManager, let tc = textContainer else { return nil }
        lm.ensureLayout(for: tc)
        let o = textContainerOrigin
        let length = (string as NSString).length
        guard length > 0, lm.numberOfGlyphs > 0 else {
            let line = lm.extraLineFragmentRect
            let font = font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            return NSPoint(x: o.x + line.minX + tc.lineFragmentPadding, y: o.y + line.minY + lm.defaultBaselineOffset(for: font))
        }
        let atEnd = sel.location >= length
        let g = lm.glyphIndexForCharacter(at: atEnd ? length - 1 : sel.location)
        let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let at = lm.location(forGlyphAt: g)
        let x = atEnd ? lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).maxX : line.minX + at.x
        return NSPoint(x: o.x + x, y: o.y + line.minY + at.y)
    }

    /// The character the block covers is drawn in `color` so it reads through the block; nil clears it.
    func invert(_ color: NSColor?) {
        guard let lm = layoutManager else { return }
        let length = (string as NSString).length
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        let i = selectedRange().location
        guard let color, selectedRange().length == 0, i < length else { return }
        lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: NSRange(location: i, length: 1))
    }
}

/// The wordmark's ▮ as the docked field's caret: drawn behind the text at the insertion point,
/// blinking while the field has the keyboard, dim and still while it doesn't, gone over a selection.
@MainActor
final class PromptCaret: NSObject {
    private unowned let view: PaletteView
    private let block = FlatView()
    private var timer: Timer?
    private var lit = true
    /// Where an empty field's caret sat when it last had the keyboard, for the idle block.
    private var restingOrigin: NSPoint?
    var color: NSColor = .white { didSet { block.fill = color } }

    init(view: PaletteView) {
        self.view = view
        super.init()
        block.isHidden = true
        view.addSubview(block, positioned: .below, relativeTo: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: nil)
        }
    }

    @objc private func keyChanged(_ note: Notification) {
        if (note.object as? NSWindow) === view.window { update() }
    }

    private var enabled: Bool { (view.field.cell as? PromptCell)?.prompt != nil }
    private var editor: PromptEditor? { view.field.currentEditor() as? PromptEditor }

    /// Re-place and restart the blink: after a keystroke the caret is solid, as everywhere on the Mac.
    func update() {
        // The editor scrolls to the caret after the selection changes; place the block once it has.
        DispatchQueue.main.async { [weak self] in self?.place(restart: true) }
    }

    private func place(restart: Bool) {
        editor?.onCaretMove = { [weak self] in self?.update() }
        guard enabled, let font = view.field.font, let origin = origin() else {
            hide(); return
        }
        let glyph = Self.cell(font)
        let r = NSRect(x: origin.x + glyph.minX, y: origin.y + glyph.minY, width: glyph.width, height: glyph.height)
        block.frame = view.backingAlignedRect(r, options: .alignAllEdgesNearest)
        let live = editor != nil && view.window?.isKeyWindow == true
        block.alphaValue = live ? 1 : 0.5
        if restart { lit = true }
        block.isHidden = !lit
        editor?.invert(live && lit ? view.owner.style.base : nil)
        timer?.invalidate(); timer = nil
        guard live, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lit.toggle()
                self.place(restart: false)
            }
        }
    }

    private func hide() {
        timer?.invalidate(); timer = nil
        block.isHidden = true
        editor?.invert(nil)
    }

    /// Insertion x and baseline in the palette view; the idle block sits only in an empty field.
    private func origin() -> NSPoint? {
        if let e = editor {
            guard let p = e.insertion else { return nil }
            let here = view.convert(p, from: e)
            if e.string.isEmpty { restingOrigin = here }
            // Scrolled out of the field's visible width: no block rather than one outside the frame.
            return view.field.frame.insetBy(dx: -2, dy: 0).contains(NSPoint(x: here.x, y: view.field.frame.midY)) ? here : nil
        }
        guard view.field.stringValue.isEmpty else { return nil }
        if let restingOrigin { return restingOrigin }
        let f = view.field, font = f.font ?? view.owner.style.monoLarge
        let text = f.cell?.drawingRect(forBounds: f.bounds) ?? f.bounds
        return view.convert(NSPoint(x: text.minX + 2, y: text.minY + ceil(font.ascender)), from: f)
    }

    /// One monospace cell around the baseline (flipped: up is negative), ascender to descender, like a
    /// terminal block: wide enough that the character under it reads through, inverted.
    private static func cell(_ font: NSFont) -> NSRect {
        let w = ("0" as NSString).size(withAttributes: [.font: font]).width
        return NSRect(x: 0, y: -ceil(font.ascender), width: ceil(w), height: ceil(font.ascender) + ceil(-font.descender))
    }
}

@MainActor
final class SidebarPaletteHeader: FlatView, NSGestureRecognizerDelegate {
    weak var owner: BrowserWindowController?
    private let back = GlyphButton(size: 24), forward = GlyphButton(size: 24), reload = GlyphButton(size: 24)
    private let hide = GlyphButton(size: 24)
    private let pill = FlatView(), square = FlatView(), url = NSTextField(labelWithString: ""), site = GlyphButton(size: 22)

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [back, forward, reload, hide, pill] { addSubview(v) }
        pill.addSubview(square); pill.addSubview(url); pill.addSubview(site)
        back.toolTip = "Back (⌘[)"; forward.toolTip = "Forward (⌘])"; reload.toolTip = "Reload (⌘R)"
        hide.toolTip = "Hide sidebar (⇧⌘L)"
        site.toolTip = "Site settings (⇧⌘I)"
        back.action = { [weak self] in self?.owner?.active?.webView?.goBack() }
        forward.action = { [weak self] in self?.owner?.active?.webView?.goForward() }
        reload.action = { [weak self] in guard let t = self?.owner?.active else { return }; if t.isLoading { t.webView?.stopLoading() } else { t.reload(fromOrigin: false) } }
        hide.action = { [weak self] in self?.owner?.toggleSidebar() }
        site.action = { [weak self] in self?.owner?.showSitePanel() }
        let click = NSClickGestureRecognizer(target: self, action: #selector(openPalette))
        click.delegate = self
        pill.addGestureRecognizer(click)
    }
    /// The pill opens the palette, except over the gear site button, which must get its own click.
    func gestureRecognizer(_ g: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        !site.bounds.contains(site.convert(event.locationInWindow, from: nil))
    }
    required init?(coder: NSCoder) { fatalError() }
    var siteButtonRectOnScreen: NSRect {
        guard let w = window else { return .zero }; return w.convertToScreen(site.convert(site.bounds, to: nil))
    }
    func applyStyle() {
        guard let o = owner else { return }; fill = o.style.sidebar
        for b in [back, forward, reload, hide, site] { b.tint = o.style.secondary; b.hoverFill = o.style.raised }
        hide.image = o.style.symbol("sidebar.left")
        hide.toolTip = o.sidebarHidden ? "Keep sidebar open (⇧⌘L)" : "Hide sidebar (⇧⌘L)"
        back.isEnabled = o.active?.webView?.canGoBack ?? false
        forward.isEnabled = o.active?.webView?.canGoForward ?? false
        back.image = o.style.symbol("chevron.left"); forward.image = o.style.symbol("chevron.right")
        reload.image = o.style.symbol(o.active?.isLoading == true ? "xmark" : "arrow.clockwise")
        reload.toolTip = o.active?.isLoading == true ? "Stop (⌘.)" : "Reload (⌘R)"
        reload.isEnabled = o.active != nil
        pill.fill = o.style.raised; pill.borderColor = o.style.border; pill.edges = .all
        square.fill = o.style.workspaceColor(o.active?.container.color ?? o.workspace.color)
        site.image = o.style.symbol("gearshape", size: o.style.glyph - 3)
        let text = o.active?.url.map(Omnibox.display) ?? ""
        let a = NSMutableAttributedString(string: text, attributes: [.font:o.style.monoSmall,.foregroundColor:o.style.secondary])
        if let host = o.active?.url?.host(), let range = text.range(of: host) { a.addAttribute(.foregroundColor, value:o.style.primary, range:NSRange(range,in:text)) }
        url.attributedStringValue = a; url.lineBreakMode = .byTruncatingTail
        let web = o.active?.url.map { $0.scheme == "http" || $0.scheme == "https" } ?? false
        site.isEnabled = web
        site.tint = (o.active?.url.map { !Browser.shared.policy(for: $0).javascript } ?? false) && web ? o.style.warn : o.style.secondary
        needsLayout = true
    }
    /// Row 1: traffic-light gap + back/forward/reload (a window drag area). Row 2: the address pill.
    static let height: CGFloat = 36 + 30

    override func layout() {
        super.layout()
        // Sidebar toggle right after the traffic lights (Safari's spot); history buttons flush right.
        let inset: CGFloat = window?.styleMask.contains(.fullScreen) == true ? 8 : 72
        let y: CGFloat = (36 - 24) / 2, w: CGFloat = 24, right = bounds.width - 6
        hide.frame = NSRect(x: inset, y: y, width: w, height: 24)
        reload.frame = NSRect(x: max(hide.frame.maxX + 2 * w + 2, right - w), y: y, width: w, height: 24)
        forward.frame = NSRect(x: reload.frame.minX - w, y: y, width: w, height: 24)
        back.frame = NSRect(x: forward.frame.minX - w, y: y, width: w, height: 24)
        pill.frame = NSRect(x: 8, y: 36, width: max(40, bounds.width - 16), height: 24)
        square.frame = NSRect(x: 7, y: 7, width: 10, height: 10)
        site.frame = NSRect(x: pill.bounds.width - 23, y: 1, width: 22, height: 22)
        let fh = ceil(url.intrinsicContentSize.height)
        url.frame = NSRect(x: 24, y: (24 - fh) / 2, width: max(0, site.frame.minX - 28), height: fh)
    }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) } }
    @objc private func openPalette() { owner?.openAddressPalette(prefill: owner?.active?.url?.absoluteString, newTab: false) }
}
