import AnglCore
import AppKit

/// The 36 px bar: traffic-light gap, sidebar toggle, back/forward/reload, URL field (which is also
/// the command palette), new tab.
@MainActor
final class NavBar: FlatView, NSTextFieldDelegate {
    /// `newTab`: a new top-level tab (the palette opened by ⌘T).
    enum Disposition { case current, newTab, childTab, newWindow }

    unowned let owner: BrowserWindowController
    var leadingInset: CGFloat = 78 { didSet { needsLayout = true } }

    private let sidebarButton = GlyphButton(size: 24)
    private let backButton = GlyphButton(size: 24)
    private let forwardButton = GlyphButton(size: 24)
    private let reloadButton = GlyphButton(size: 24)
    private let newTabButton = GlyphButton(size: 24)
    private let box = FlatView()
    private let square = FlatView()
    let field = URLTextField()
    private let siteButton = GlyphButton(size: 22)
    private let progressBar = FlatView()
    private let suggestions = SuggestionsPanel()
    private(set) var editing = false
    /// The user typed (or a prefill was given) since the field took focus.
    private(set) var typed = false

    init(owner: BrowserWindowController) {
        self.owner = owner
        super.init(frame: .zero)
        for b in [sidebarButton, backButton, forwardButton, reloadButton, newTabButton] {
            b.translatesAutoresizingMaskIntoConstraints = true
            addSubview(b)
        }
        siteButton.translatesAutoresizingMaskIntoConstraints = true
        addSubview(box)
        box.addSubview(square)
        box.addSubview(field)
        box.addSubview(siteButton)
        box.addSubview(progressBar)
        sidebarButton.action = { [weak owner] in owner?.toggleSidebar() }
        backButton.action = { [weak owner] in owner?.active?.webView?.goBack() }
        forwardButton.action = { [weak owner] in owner?.active?.webView?.goForward() }
        reloadButton.action = { [weak owner] in
            guard let t = owner?.active else { return }
            if t.isLoading { t.webView?.stopLoading() } else { t.reload(fromOrigin: false) }
        }
        newTabButton.action = { [weak owner] in owner?.newTab() }
        siteButton.action = { [weak owner] in owner?.showSitePanel() }
        sidebarButton.toolTip = "Toggle sidebar (⇧⌘L)"
        backButton.toolTip = "Back (⌘[)"
        forwardButton.toolTip = "Forward (⌘])"
        newTabButton.toolTip = "New tab (⌘T)"
        siteButton.toolTip = "Site settings (⇧⌘I)"

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.placeholderString = "search or address (> for commands)"
        field.onFocus = { [weak self] in if self?.editing == false { self?.beginEditing(prefill: nil) } }
        suggestions.onPick = { [weak self] s, d in self?.run(s, d) }
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyStyle() {
        let s = owner.style
        fill = s.base
        borderColor = s.border
        edges = .bottom
        for b in [sidebarButton, backButton, forwardButton, reloadButton, newTabButton, siteButton] {
            b.tint = s.secondary
            b.hoverFill = s.raised
        }
        siteButton.image = s.symbol("gearshape", size: s.glyph - 3)
        sidebarButton.image = s.symbol("sidebar.left")
        backButton.image = s.symbol("chevron.left")
        forwardButton.image = s.symbol("chevron.right")
        newTabButton.image = s.symbol("plus")
        box.fill = s.raised
        box.borderColor = s.border
        box.edges = .all
        field.font = s.mono
        field.textColor = s.primary
        progressBar.fill = s.accent
        suggestions.style = s
        update()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x = leadingInset
        for b in [sidebarButton, backButton, forwardButton, reloadButton] {
            b.frame = NSRect(x: x, y: (h - 24) / 2, width: 24, height: 24)
            x += 26
        }
        x += 6
        newTabButton.frame = NSRect(x: bounds.width - 8 - 24, y: (h - 24) / 2, width: 24, height: 24)
        box.frame = NSRect(x: x, y: (h - 24) / 2, width: max(80, newTabButton.frame.minX - 8 - x), height: 24)
        square.frame = NSRect(x: 8, y: 7, width: 10, height: 10)
        siteButton.frame = NSRect(x: box.bounds.width - 23, y: 1, width: 22, height: 22)
        let fh = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: 24, y: (24 - fh) / 2, width: siteButton.frame.minX - 28, height: fh)
        updateProgress()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }

    var siteButtonRectOnScreen: NSRect {
        guard let w = window else { return .zero }
        return w.convertToScreen(siteButton.convert(siteButton.bounds, to: nil))
    }

    private var boxRectOnScreen: NSRect {
        guard let w = window else { return .zero }
        return w.convertToScreen(box.convert(box.bounds, to: nil))
    }

    // MARK: State

    func update() {
        let s = owner.style
        let t = owner.active
        backButton.isEnabled = t?.webView?.canGoBack ?? false
        forwardButton.isEnabled = t?.webView?.canGoForward ?? false
        reloadButton.image = s.symbol(t?.isLoading == true ? "xmark" : "arrow.clockwise")
        reloadButton.toolTip = t?.isLoading == true ? "Stop (⌘.)" : "Reload (⌘R)"
        if let t {
            let c = t.container
            square.fill = s.workspaceColor(c.color)
            square.toolTip = c.name + (c.proxy.map { " · \($0.label)" } ?? "")
            let p = Browser.shared.policy(for: t.url)
            let web = t.url?.scheme == "http" || t.url?.scheme == "https"
            siteButton.isEnabled = web
            siteButton.tint = !p.javascript && web ? s.warn : s.secondary
        }
        if !editing {
            showDisplayURL()
        } else if !typed, let url = t?.url {
            // Focused but untouched: follow navigation (e.g. a URL opened from another app).
            field.stringValue = url.absoluteString
            field.textColor = s.primary
            field.currentEditor()?.selectAll(nil)
        }
        updateProgress()
        owner.sidebar?.updatePaletteHeader()
    }

    func updateProgress() {
        guard let t = owner.active, t.isLoading else { progressBar.isHidden = true; return }
        progressBar.isHidden = false
        progressBar.frame = NSRect(x: 0, y: box.bounds.height - 2, width: box.bounds.width * max(0.05, t.progress), height: 2)
    }

    private func showDisplayURL() {
        let s = owner.style
        guard let url = owner.active?.url else { field.stringValue = ""; return }
        let text = url.scheme == InternalPages.scheme ? url.absoluteString : Omnibox.display(url)
        let a = NSMutableAttributedString(string: text, attributes: [.font: s.mono, .foregroundColor: s.secondary])
        if let host = url.host(), let r = text.range(of: host) {
            a.addAttribute(.foregroundColor, value: s.primary, range: NSRange(r, in: text))
        }
        field.attributedStringValue = a
    }

    // MARK: Editing

    func focusField(prefill: String?) {
        window?.makeFirstResponder(field)
        beginEditing(prefill: prefill)
    }

    private func beginEditing(prefill: String?) {
        editing = true
        typed = prefill != nil
        if let prefill {
            field.stringValue = prefill
            field.currentEditor()?.selectedRange = NSRange(location: prefill.count, length: 0)
            refreshSuggestions()
        } else {
            field.stringValue = owner.active?.url?.absoluteString ?? ""
            field.textColor = owner.style.primary
            field.currentEditor()?.selectAll(nil)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        editing = true
        typed = true
        refreshSuggestions()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        editing = false
        typed = false
        closeSuggestions()
        showDisplayURL()
        owner.urlFieldEnded()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): suggestions.move(1); return true
        case #selector(NSResponder.moveUp(_:)): suggestions.move(-1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            let d: Disposition = flags.contains(.shift) ? .newWindow : flags.contains(.command) ? .childTab : .current
            if let s = suggestions.selected { run(s, d) } else { commit(field.stringValue, d) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if suggestions.isVisible { closeSuggestions() } else { endEditing() }
            return true
        default:
            return false
        }
    }

    private func endEditing() {
        window?.makeFirstResponder(nil)
        owner.focusContent()
    }

    private func commit(_ text: String, _ d: Disposition) {
        OmniboxEditing.commit(text, window: owner, disposition: d, close: endEditing)
    }

    private func run(_ s: Suggestion, _ d: Disposition) {
        OmniboxEditing.run(s, disposition: d, close: endEditing)
    }

    func closeSuggestions() { suggestions.hide() }

    /// Bookmark edits from a row's context menu show up in the open drop-down.
    func bookmarksChanged() { if suggestions.isVisible { refreshSuggestions() } }

    private func refreshSuggestions() {
        let items = Suggestions.compute(field.stringValue, window: owner)
        if items.isEmpty { suggestions.hide(); return }
        suggestions.show(items, below: boxRectOnScreen, parent: window)
    }
}

/// Text field that reports when it gains focus (click or Cmd-L).
final class URLTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        // Deferred so the field editor exists; skipped if focus already moved on (e.g. Return → page).
        if ok { DispatchQueue.main.async { [weak self] in if self?.currentEditor() != nil { self?.onFocus?() } } }
        return ok
    }
}

// MARK: - Suggestions

struct Suggestion {
    enum Kind { case go, search, tab, history, bookmark, archive, command }
    var kind: Kind
    var title: String
    var detail: String
    var hint: String
    var hintColor: NSColor?
    /// Right-click menu for the row (bookmarks).
    var menu: (@MainActor () -> NSMenu)? = nil
    var act: @MainActor (NavBar.Disposition) -> Void

    var glyph: String {
        switch kind {
        case .go: "arrow.right"
        case .search: "magnifyingglass"
        case .tab: "square.on.square"
        case .history: "clock"
        case .bookmark: "bookmark"
        case .archive: "archivebox"
        case .command: "chevron.right"
        }
    }
}

@MainActor
enum Suggestions {
    static let limit = 8

    static func compute(_ text: String, window w: BrowserWindowController) -> [Suggestion] {
        let b = Browser.shared!
        switch Omnibox.parse(text, settings: b.settings.search) {
        case .empty:
            return []
        case .command(let q):
            return Commands.palette(q, window: w).prefix(limit).map { e in
                Suggestion(kind: .command, title: e.title, detail: e.detail, hint: e.hint) { _ in e.run(w) }
            }
        case .filter(.tabs, let q):
            return Array(tabs(q, w).prefix(limit))
        case .filter(.history, let q):
            return (b.history?.query(q, limit: limit, offset: 0) ?? []).map { history($0, w) }
        case .filter(.bookmarks, let q):
            return b.bookmarks.search(q, limit: limit).compactMap { bookmark($0, w) }
        case .filter(.archive, let q):
            return (b.history?.recovery(reason: .archived, text: q, limit: limit) ?? []).map { archive($0, w) }
        case .navigate(let url):
            let typed = text.trimmingCharacters(in: .whitespaces)
            let isAddress = Omnibox.urlIfAddress(typed) != nil
            var out = [Suggestion(kind: isAddress ? .go : .search, title: typed,
                                  detail: isAddress ? "" : "search · \(url.host() ?? "")", hint: "↩") { d in w.go(url, disposition: d) }]
            var seen: Set<String> = [url.absoluteString]
            for s in tabs(typed, w).prefix(3) { out.append(s) }
            for bm in b.bookmarks.search(typed, limit: 3) where seen.insert(bm.url ?? "").inserted {
                if let s = bookmark(bm, w) { out.append(s) }
            }
            for h in b.history?.suggest(typed, limit: limit) ?? [] where seen.insert(h.url).inserted {
                out.append(history(h, w))
                if out.count >= limit { break }
            }
            return Array(out.prefix(limit))
        }
    }

    private static func tabs(_ q: String, _ w: BrowserWindowController) -> [Suggestion] {
        let terms = q.lowercased().split(separator: " ").map(String.init)
        var out: [Suggestion] = []
        for ws in Browser.shared.workspaces.workspaces {
            guard let tr = w.trees[ws.id] else { continue }
            for n in tr.allTabs {
                let hay = (n.title + " " + (n.url?.absoluteString ?? "")).lowercased()
                guard terms.allSatisfy({ hay.contains($0) }), n !== w.active?.node else { continue }
                out.append(Suggestion(kind: .tab, title: n.title.isEmpty ? "New Tab" : n.title,
                                      detail: n.url.map(Omnibox.display) ?? "", hint: "■",
                                      hintColor: w.style.workspaceColor(ws.color)) { _ in w.activate(w.tab(n)) })
            }
        }
        return out
    }

    private static func history(_ h: HistoryItem, _ w: BrowserWindowController) -> Suggestion {
        Suggestion(kind: .history, title: h.title.isEmpty ? h.url : h.title,
                   detail: URL(string: h.url).map(Omnibox.display) ?? h.url, hint: "") { d in
            if let u = URL(string: h.url) { w.go(u, disposition: d) }
        }
    }

    private static func archive(_ record: RecoveryRecord, _ w: BrowserWindowController) -> Suggestion {
        Suggestion(kind: .archive, title: record.saved.title.isEmpty ? (record.saved.url ?? "New Tab") : record.saved.title,
                   detail: record.saved.url.flatMap(URL.init(string:)).map(Omnibox.display) ?? "", hint: "↩") { _ in
            guard w.restore(record) else { return }
            _ = Browser.shared.history?.deleteRecovery(id: record.id)
        }
    }

    private static func bookmark(_ bm: Bookmark, _ w: BrowserWindowController) -> Suggestion? {
        guard let s = bm.url, let u = URL(string: s) else { return nil }
        return Suggestion(kind: .bookmark, title: bm.title, detail: Omnibox.display(u), hint: "", menu: { BookmarkMenu.make(bm, w) }) { d in w.go(u, disposition: d) }
    }
}


@MainActor
enum OmniboxEditing {
    static func commit(_ text: String, window: BrowserWindowController, disposition: NavBar.Disposition,
                       close: () -> Void) {
        switch Omnibox.parse(text, settings: Browser.shared.settings.search) {
        case .navigate(let url):
            close()
            window.go(url, disposition: disposition)
        case .command(let query):
            if let entry = Commands.palette(query, window: window).first { close(); entry.run(window) }
        case .filter, .empty: break
        }
    }

    static func run(_ suggestion: Suggestion, disposition: NavBar.Disposition, close: () -> Void) {
        close()
        suggestion.act(disposition)
    }
}

/// Borderless drop-down under the URL field. Never takes key focus; the field keeps typing.
@MainActor
final class SuggestionsPanel {
    var onPick: ((Suggestion, NavBar.Disposition) -> Void)?
    var style: Style?
    private var panel: NSPanel?
    private let list = SuggestionList()
    private(set) var items: [Suggestion] = []
    private(set) var index = 0

    var isVisible: Bool { panel?.isVisible ?? false }
    var selected: Suggestion? { isVisible && items.indices.contains(index) ? items[index] : nil }

    func show(_ items: [Suggestion], below rect: NSRect, parent: NSWindow?) {
        self.items = items
        index = 0
        let p = panel ?? makePanel()
        let h = CGFloat(items.count) * SuggestionList.rowHeight + 2
        p.setFrame(NSRect(x: rect.minX, y: rect.minY - h + 1, width: rect.width, height: h), display: false)
        list.style = style
        list.items = items
        list.selected = 0
        list.onPick = { [weak self] i in
            guard let self, self.items.indices.contains(i) else { return }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            self.onPick?(self.items[i], flags.contains(.command) ? .childTab : flags.contains(.shift) ? .newWindow : .current)
        }
        list.frame = p.contentView!.bounds
        if p.parent == nil { parent?.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
    }

    func move(_ delta: Int) {
        guard isVisible, !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
        list.selected = index
    }

    func hide() {
        guard let p = panel else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.hasShadow = true
        p.isOpaque = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = true
        list.autoresizingMask = [.width, .height]
        p.contentView = list
        panel = p
        return p
    }
}

/// Rows drawn by hand: glyph, title, mono detail, hint.
final class SuggestionList: NSView {
    static let rowHeight: CGFloat = 28
    var style: Style?
    var items: [Suggestion] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func row(at p: NSPoint) -> Int { Int((p.y - 1) / SuggestionList.rowHeight) }

    override func mouseMoved(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if items.indices.contains(r) { selected = r }
    }

    override func mouseUp(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if items.indices.contains(r) { onPick?(r) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let r = row(at: convert(event.locationInWindow, from: nil))
        guard items.indices.contains(r), let make = items[r].menu else { return nil }
        selected = r
        return make()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = style else { return }
        s.raised.setFill(); bounds.fill()
        for (i, item) in items.enumerated() {
            let y = 1 + CGFloat(i) * SuggestionList.rowHeight
            let r = NSRect(x: 1, y: y, width: bounds.width - 2, height: SuggestionList.rowHeight)
            if i == selected {
                s.selected.setFill(); r.fill()
                s.accent.setFill(); NSRect(x: 1, y: y, width: 2, height: r.height).fill()
            }
            if let img = s.symbol(item.glyph)?.tinted(s.secondary) {
                img.draw(in: NSRect(x: 10, y: y + (r.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
            }
            var hintW: CGFloat = 0
            if !item.hint.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: s.monoSmall, .foregroundColor: item.hintColor ?? s.muted]
                let size = (item.hint as NSString).size(withAttributes: attrs)
                hintW = size.width + 16
                (item.hint as NSString).draw(at: NSPoint(x: r.maxX - size.width - 10, y: y + (r.height - size.height) / 2), withAttributes: attrs)
            }
            let textX: CGFloat = 32
            let avail = r.maxX - textX - hintW - 8
            let title = NSAttributedString(string: item.title, attributes: [.font: s.ui, .foregroundColor: s.primary])
            let titleW = min(title.size().width, item.detail.isEmpty ? avail : avail * 0.55)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let tAttrs: [NSAttributedString.Key: Any] = [.font: s.ui, .foregroundColor: s.primary, .paragraphStyle: para]
            let lineH = s.ui.boundingRectForFont.height
            (item.title as NSString).draw(in: NSRect(x: textX, y: y + (r.height - lineH) / 2, width: titleW, height: lineH), withAttributes: tAttrs)
            if !item.detail.isEmpty {
                let dAttrs: [NSAttributedString.Key: Any] = [.font: s.monoSmall, .foregroundColor: s.secondary, .paragraphStyle: para]
                let dh = s.monoSmall.boundingRectForFont.height
                let dx = textX + titleW + 10
                (item.detail as NSString).draw(in: NSRect(x: dx, y: y + (r.height - dh) / 2, width: max(0, avail - titleW - 10), height: dh),
                                               withAttributes: dAttrs)
            }
        }
        s.border.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}
