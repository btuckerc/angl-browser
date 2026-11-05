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
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            suggestions.move(selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
            owner.preconnect(suggestions.selected?.preconnect, newTab: false)
            return true
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
        owner.preconnect(suggestions.selected?.preconnect, newTab: false)
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
    /// Where the row navigates, when that is worth warming a connection to before it's picked:
    /// searches, visited pages and bookmarks, not arbitrary text that merely looks like a host.
    var preconnect: URL? = nil
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

    /// What VoiceOver reads for the row: title, address, kind, and a command's shortcut.
    var accessibilityLabel: String {
        let kindName = switch kind {
        case .go: "go to address"
        case .search: "search"
        case .tab: "open tab"
        case .history: "history"
        case .bookmark: "bookmark"
        case .archive: "archived tab"
        case .command: "command"
        }
        return [title, detail, kindName, kind == .command ? hint : ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

@MainActor
enum Suggestions {
    /// The mixed list under a typed address or search.
    static let limit = 8
    /// A filter (`h `, `b `, `a `) lists this many; the list scrolls past `SuggestionList.visible`.
    static let filterLimit = 50

    static func compute(_ text: String, window w: BrowserWindowController) -> [Suggestion] {
        let b = Browser.shared!
        switch Omnibox.parse(text, settings: b.settings.search) {
        case .empty:
            return recentTabs(w)
        case .command(let q):
            return Commands.palette(q, window: w).map { e in
                Suggestion(kind: .command, title: e.title, detail: e.detail, hint: e.hint) { _ in e.run(w) }
            }
        case .filter(.tabs, let q):
            return tabMatches(q, w).map { tab($0, $1, w) }
        case .filter(.history, let q):
            return (b.history?.query(q, limit: filterLimit, offset: 0) ?? []).map { history($0, w) }
        case .filter(.bookmarks, let q):
            return b.bookmarks.search(q, limit: filterLimit).compactMap { bookmark($0, w) }
        case .filter(.archive, let q):
            return (b.history?.recovery(reason: .archived, text: q, limit: filterLimit) ?? []).map { archive($0, w) }
        case .navigate(let url):
            let typed = text.trimmingCharacters(in: .whitespaces)
            let isAddress = Omnibox.urlIfAddress(typed) != nil
            var out = [Suggestion(kind: isAddress ? .go : .search, title: typed,
                                  detail: isAddress ? "" : "search · \(url.host() ?? "")", hint: "↩",
                                  preconnect: isAddress ? nil : url) { d in w.go(url, disposition: d) }]
            var seen: Set<String> = [url.absoluteString]
            // An open tab stands for its page: the same URL doesn't come back as a bookmark or history row.
            for (n, ws) in tabMatches(typed, w).prefix(3) {
                out.append(tab(n, ws, w))
                if let u = n.url { seen.insert(u.absoluteString) }
            }
            for bm in b.bookmarks.search(typed, limit: 3) where seen.insert(bm.url ?? "").inserted {
                if let s = bookmark(bm, w) { out.append(s) }
            }
            for h in b.history?.suggest(typed, limit: limit) ?? [] where seen.insert(h.url).inserted {
                out.append(history(h, w))
                if out.count >= limit { break }
            }
            // A typed address is warmed once history or bookmarks show its host is real.
            let site = { (u: URL?) in u?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } }
            if isAddress, let host = site(url), out.contains(where: { site($0.preconnect) == host }) { out[0].preconnect = url }
            return Array(out.prefix(limit))
        }
    }

    private static func tabMatches(_ q: String, _ w: BrowserWindowController) -> [(TabNode, Workspace)] {
        let terms = q.lowercased().split(separator: " ").map(String.init)
        var out: [(TabNode, Workspace)] = []
        for ws in Browser.shared.workspaces.workspaces {
            guard let tr = w.trees[ws.id] else { continue }
            for n in tr.allTabs {
                let hay = (n.title + " " + (n.url?.absoluteString ?? "")).lowercased()
                guard terms.allSatisfy({ hay.contains($0) }), n !== w.active?.node else { continue }
                out.append((n, ws))
            }
        }
        return out
    }

    /// Empty field: this window's other tabs, most recently used first.
    private static func recentTabs(_ w: BrowserWindowController) -> [Suggestion] {
        tabMatches("", w).sorted { $0.0.lastActive > $1.0.lastActive }
            .prefix(limit).map { tab($0, $1, w) }
    }

    private static func tab(_ n: TabNode, _ ws: Workspace, _ w: BrowserWindowController) -> Suggestion {
        Suggestion(kind: .tab, title: n.title.isEmpty ? "New Tab" : n.title,
                   detail: n.url.map(Omnibox.display) ?? "", hint: "■",
                   hintColor: w.style.workspaceColor(ws.color)) { _ in w.activate(w.tab(n)) }
    }

    private static func history(_ h: HistoryItem, _ w: BrowserWindowController) -> Suggestion {
        Suggestion(kind: .history, title: h.title.isEmpty ? h.url : h.title,
                   detail: URL(string: h.url).map(Omnibox.display) ?? h.url, hint: "", preconnect: URL(string: h.url)) { d in
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
        return Suggestion(kind: .bookmark, title: bm.title, detail: Omnibox.display(u), hint: "", menu: { BookmarkMenu.make(bm, w) },
                          preconnect: u) { d in w.go(u, disposition: d) }
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
    var items: [Suggestion] { list.items }

    var isVisible: Bool { panel?.isVisible ?? false }
    var selected: Suggestion? { isVisible ? list.current : nil }

    func show(_ items: [Suggestion], below rect: NSRect, parent: NSWindow?) {
        let p = panel ?? makePanel()
        let h = SuggestionList.height(for: items.count)
        p.setFrame(NSRect(x: rect.minX, y: rect.minY - h + 1, width: rect.width, height: h), display: false)
        list.style = style
        list.items = items
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
        guard isVisible else { return }
        list.move(delta)
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

/// Rows drawn by hand: glyph, title, mono detail, hint. At most `visible` rows show; the rest scroll
/// (wheel, or following the selection). The list owns the selection, so the row under the mouse, the
/// row ↑ ↓ reach and the row Return picks are the same one.
final class SuggestionList: NSView {
    static let rowHeight: CGFloat = 28
    static let visible = 8
    var style: Style?
    var items: [Suggestion] = [] {
        didSet {
            top = 0; wheel = 0; selected = 0; needsDisplay = true
            // Rebuilt when an AX client next asks, not on every keystroke.
            if axRows != nil { axRows = nil; NSAccessibility.post(element: self, notification: .layoutChanged) }
        }
    }
    var selected = 0 {
        didSet {
            guard selected != oldValue else { return }
            reveal()
            needsDisplay = true
            guard let axRows else { return }
            for (i, e) in axRows.enumerated() { e.setAccessibilitySelected(i == selected) }
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
    }
    var onPick: ((Int) -> Void)?
    var current: Suggestion? { items.indices.contains(selected) ? items[selected] : nil }
    /// The first row on screen.
    private var top = 0
    /// Scroll-wheel travel not yet worth a whole row.
    private var wheel: CGFloat = 0
    /// VoiceOver sees one element per row; kept here because AX doesn't retain them. Nil until asked for.
    private var axRows: [PressableElement]?

    /// The list's height for `count` rows: the visible ones plus the 1 pt border.
    static func height(for count: Int) -> CGFloat { CGFloat(min(count, visible)) * rowHeight + 2 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Suggestions")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ↑ ↓ from the field, wrapping at the ends. VoiceOver stays in the field, so the row is read out.
    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
        if NSWorkspace.shared.isVoiceOverEnabled, let item = current {
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: item.accessibilityLabel,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func reveal() {
        if selected < top { top = selected } else if selected >= top + Self.visible { top = selected - Self.visible + 1 }
        layoutAccessibility()
    }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 1, y: 1 + CGFloat(i - top) * Self.rowHeight, width: bounds.width - 2, height: Self.rowHeight)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func row(at p: NSPoint) -> Int { top + Int((p.y - 1) / SuggestionList.rowHeight) }

    override func mouseMoved(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if items.indices.contains(r) { selected = r }
    }

    override func scrollWheel(with event: NSEvent) {
        guard items.count > Self.visible else { return }
        wheel += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.rowHeight
        let steps = Int(wheel / Self.rowHeight)
        guard steps != 0 else { return }
        wheel -= CGFloat(steps) * Self.rowHeight
        top = min(max(0, top - steps), items.count - Self.visible)
        layoutAccessibility()
        needsDisplay = true
        mouseMoved(with: event)
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

    override func accessibilityChildren() -> [Any]? {
        if let axRows { return axRows }
        let rows = items.enumerated().map { i, item in
            let e = PressableElement()
            e.setAccessibilityElement(true)
            e.setAccessibilityRole(.row)
            e.setAccessibilityLabel(item.accessibilityLabel)
            e.setAccessibilityParent(self)
            e.setAccessibilitySelected(i == selected)
            e.press = { [weak self] in
                guard let self, self.items.indices.contains(i) else { return false }
                self.selected = i
                self.onPick?(i)
                return true
            }
            return e
        }
        axRows = rows
        layoutAccessibility()
        return rows
    }

    /// AX parent space is bottom-up even for a flipped view: without the flip VoiceOver's cursor lands on
    /// the mirrored row.
    private func layoutAccessibility() {
        for (i, e) in (axRows ?? []).enumerated() {
            var r = rowRect(i)
            r.origin.y = bounds.height - r.maxY
            e.setAccessibilityFrameInParentSpace(r)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutAccessibility()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = style else { return }
        s.raised.setFill(); bounds.fill()
        for i in items.indices.clamped(to: top..<(top + Self.visible)) {
            let item = items[i]
            let r = rowRect(i), y = r.minY
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
        // More rows than fit: a thumb on the right edge says where the view is.
        if items.count > Self.visible {
            let track = bounds.height - 2, n = CGFloat(items.count)
            s.border.setFill()
            NSRect(x: bounds.width - 4, y: 1 + track * CGFloat(top) / n, width: 2, height: track * CGFloat(Self.visible) / n).fill()
        }
        s.border.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}
