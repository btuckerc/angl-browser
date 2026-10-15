import AnglCore
import AppKit

extension NSPasteboard.PasteboardType {
    static let anglTab = NSPasteboard.PasteboardType("dev.btuckerc.angl.tab")
}

/// Space squares, favourites, pinned rows, the tab tree and the downloads footer.
@MainActor
final class SidebarView: FlatView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    unowned let owner: BrowserWindowController
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private let strip: WorkspaceStrip
    private let favorites: FavoriteStrip
    private let pinned: PinnedRows
    private let scroll = SidebarScrollView()
    let outline = TabOutlineView()
    private let footer: DownloadsFooter
    private var outlineColorOverride: NSColor?
    private var outlineWidth: CGFloat = 1
    private var outlineVisible = false
    private var renaming: TabNode?
    /// True while reloadData re-expands rows; expand/collapse callbacks must not persist it.
    private var syncing = false

    var tree: TabTree { owner.tree }
    private let paletteHeader = SidebarPaletteHeader()
    var paletteHeaderVisible = false { didSet { paletteHeader.isHidden = !paletteHeaderVisible; needsLayout = true } }
    var siteButtonRectOnScreen: NSRect { paletteHeader.siteButtonRectOnScreen }

    var style: Style { owner.style }

    init(owner: BrowserWindowController) {
        self.owner = owner
        strip = WorkspaceStrip(owner: owner)
        favorites = FavoriteStrip(owner: owner)
        pinned = PinnedRows(owner: owner)
        footer = DownloadsFooter(owner: owner)
        super.init(frame: .zero)
        let col = NSTableColumn(identifier: .init("tab"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .plain
        outline.rowSizeStyle = .custom
        outline.intercellSpacing = .zero
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.allowsMultipleSelection = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.registerForDraggedTypes([.anglTab, .URL, .string])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.owner = owner
        outline.sidebar = self
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.owner = owner
        paletteHeader.owner = owner
        addSubview(paletteHeader)

        for v: NSView in [favorites, strip, pinned, scroll, footer] { addSubview(v) }
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }
    func updateOutline(color: NSColor, width: CGFloat, visible: Bool) {
        outlineColorOverride = color
        outlineWidth = width
        outlineVisible = visible
        borderColor = visible ? nil : style.border
        edges = visible ? [] : .right
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard outlineVisible, let color = outlineColorOverride else { return }
        color.setFill()
        NSRect(x: bounds.width - outlineWidth, y: 0, width: outlineWidth, height: bounds.height).fill()
    }

    func applyStyle() {
        fill = style.sidebar
        borderColor = style.border
        edges = .right
        outline.indentationPerLevel = style.indent
        footer.applyStyle()
        paletteHeader.applyStyle()
        needsLayout = true
        reload()
    }

    override func layout() {
        super.layout()
        let w = bounds.width - 1
        let headerH: CGFloat = paletteHeaderVisible ? SidebarPaletteHeader.height : 0
        paletteHeader.frame = NSRect(x: 0, y: 0, width: w, height: headerH)
        let top = headerH
        let fh: CGFloat = footer.isHidden ? 0 : 24
        footer.frame = NSRect(x: 0, y: bounds.height - fh, width: w, height: fh)
        let selector = owner.browser.theme.sidebar.spaces
        let stripAtBottom = selector == .bottom
        let stripH: CGFloat = selector == .hidden ? 0 : 28
        strip.isHidden = selector == .hidden
        let favoritesH: CGFloat = owner.browser.settings.tabs.favorites && !owner.browser.bookmarks.favorites().isEmpty ? 28 : 0
        favorites.isHidden = favoritesH == 0
        favorites.frame = NSRect(x: 0, y: top, width: w, height: favoritesH)
        let selectorY = top + favoritesH
        strip.frame = NSRect(x: 0, y: stripAtBottom ? bounds.height - fh - stripH : selectorY, width: w, height: stripH)
        let ph = pinned.height(for: w)
        let pinnedY = stripAtBottom ? selectorY : selectorY + stripH
        pinned.frame = NSRect(x: 0, y: pinnedY, width: w, height: ph)
        let treeY = pinnedY + ph
        scroll.frame = NSRect(x: 0, y: treeY, width: w, height: max(0, bounds.height - treeY - fh - stripH * (stripAtBottom ? 1 : 0)))
        outline.tableColumns.first?.width = scroll.contentSize.width
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }

    // MARK: Reload

    func reload() {
        favorites.needsDisplay = true
        strip.needsDisplay = true
        pinned.needsDisplay = true
        needsLayout = true
        paletteHeader.applyStyle()
        guard renaming == nil else { return }
        syncing = true
        outline.reloadData()
        func expand(_ n: TabNode) {
            guard !n.children.isEmpty || n.isFolder else { return }
            if n.collapsed { outline.collapseItem(n) } else { outline.expandItem(n) }
            n.children.forEach(expand)
        }
        tree.root.children.forEach(expand)
        syncing = false
        if let a = owner.active?.node {
            let row = outline.row(forItem: a)
            if row >= 0 {
                if !outline.selectedRowIndexes.contains(row) || outline.selectedRowIndexes.count > 1 {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                }
                outline.scrollRowToVisible(row)
            } else {
                outline.deselectAll(nil)
            }
        }
        updateFooter()
    }

    func reload(node: TabNode) {
        let row = outline.row(forItem: node)
        if row >= 0, renaming == nil {
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCell { configure(cell, node) }
            (outline.rowView(atRow: row, makeIfNecessary: false) as? TabRowView).map { configure($0, node) }
        } else {
            pinned.needsDisplay = true
        }
    }
    func updatePaletteHeader() { paletteHeader.applyStyle() }

    func updateFooter() {
        let was = footer.isHidden
        footer.update()
        if was != footer.isHidden { needsLayout = true }
    }

    func focusTree() {
        window?.makeFirstResponder(outline)
        if outline.selectedRow < 0, outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? TabNode) ?? tree.root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? TabNode) ?? tree.root).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? TabNode else { return false }
        return n.isFolder || !n.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let n = item as? TabNode else { return nil }
        let p = NSPasteboardItem()
        p.setString(n.id.uuidString, forType: .anglTab)
        if let u = n.url { p.setString(u.absoluteString, forType: .URL); p.setString(u.absoluteString, forType: .string) }
        return p
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let target = item as? TabNode
        let dragged = draggedNodes(info)
        if !dragged.isEmpty {
            for d in dragged where target === d || (target.map { d.isAncestor(of: $0) } ?? false) { return [] }
            if target == nil, index == NSOutlineViewDropOnItemIndex {
                outlineView.setDropItem(nil, dropChildIndex: tree.root.children.count)
            }
            return .move
        }
        return droppedURLs(info).isEmpty ? [] : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let parent = item as? TabNode
        let dragged = draggedNodes(info)
        if !dragged.isEmpty {
            var i = index
            for n in dragged {
                let container = parent ?? tree.root
                if i != NSOutlineViewDropOnItemIndex, n.parent === container,
                   let old = container.children.firstIndex(where: { $0 === n }), old < i {
                    i -= 1
                }
                tree.insert(n, under: parent, at: i == NSOutlineViewDropOnItemIndex ? nil : i)
                if i != NSOutlineViewDropOnItemIndex { i += 1 }
            }
            parent?.collapsed = false
            owner.browser.markSessionDirty()
            reload()
            return true
        }
        let urls = droppedURLs(info)
        guard !urls.isEmpty else { return false }
        for u in urls {
            if let p = parent, !p.isFolder { owner.openChild(of: owner.tab(p), url: u, configuration: nil, activate: false) }
            else {
                let n = TabNode.tab(u)
                tree.insert(n, under: parent, at: index == NSOutlineViewDropOnItemIndex ? nil : index)
                owner.tab(n).load()
            }
        }
        reload()
        return true
    }

    func draggedNodes(_ info: any NSDraggingInfo) -> [TabNode] {
        guard info.draggingSource as? NSView != nil else { return [] }
        let ids = info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: .anglTab) } ?? []
        // Drop children whose ancestor is also dragged: they travel with it.
        let nodes = ids.compactMap { UUID(uuidString: $0) }.compactMap { owner.tree.node($0) }
        return nodes.filter { n in !nodes.contains { $0 !== n && $0.isAncestor(of: n) } }
    }

    private func droppedURLs(_ info: any NSDraggingInfo) -> [URL] {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty { return urls }
        if let s = pb.string(forType: .string), let u = Omnibox.urlIfAddress(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return [u]
        }
        return []
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { style.row }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rv = TabRowView()
        if let n = item as? TabNode { configure(rv, n) }
        return rv
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? TabNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: TabCell.id, owner: nil) as? TabCell) ?? TabCell()
        cell.sidebar = self
        configure(cell, n)
        return cell
    }

    private func configure(_ rv: TabRowView, _ n: TabNode) {
        rv.style = style
        rv.isActiveTab = owner.active?.node === n
        rv.isSplitPartner = !rv.isActiveTab && owner.isSplitMember(n)
        let c = owner.container(for: n)
        rv.containerColor = !n.isFolder && n.containerID != nil && c.id != owner.workspace.containerID
            ? style.workspaceColor(c.color) : nil
        rv.needsDisplay = true
    }

    func configure(_ cell: TabCell, _ n: TabNode) {
        let s = style
        cell.node = n
        cell.title.font = s.ui
        cell.badge.font = s.monoSmall
        cell.badge.textColor = s.secondary
        cell.close.tint = s.secondary
        cell.close.hoverFill = s.selected
        cell.close.image = s.symbol("xmark", size: 9, weight: .semibold)
        if n.isFolder {
            cell.title.stringValue = n.title
            cell.title.textColor = s.secondary
            cell.icon.image = s.symbol("folder")?.tinted(s.secondary)
            cell.icon.alphaValue = 1
            let count = n.subtree.filter { !$0.isFolder }.count
            cell.badge.stringValue = n.collapsed && count > 0 ? "\(count)" : ""
            cell.audio.isHidden = true
        } else {
            let t = owner.liveTab(n)
            cell.title.stringValue = t?.displayTitle ?? (n.title.isEmpty ? n.url.map(Omnibox.display) ?? "New Tab" : n.title)
            let loaded = t?.isLoaded == true || owner.active?.node === n
            cell.title.textColor = loaded ? s.primary : s.muted
            let internalPage = n.url?.scheme == InternalPages.scheme
            cell.icon.image = t?.favicon ?? Tab.storedFavicon(for: n.url)
                ?? (internalPage ? s.symbol("square.fill", size: 10)?.tinted(s.accent)
                    : s.symbol(n.url == nil ? "plus.square.dashed" : "globe")?.tinted(s.muted))
            cell.icon.alphaValue = loaded ? 1 : 0.55
            cell.badge.stringValue = n.collapsed && !n.children.isEmpty ? "\(n.subtree.count - 1)" : ""
            let muted = t?.muted ?? false
            cell.audio.isHidden = !muted && !(t?.isPlaying ?? false)
            cell.audio.image = s.symbol(muted ? "speaker.slash" : "speaker.wave.2", size: 10)?.tinted(s.muted)
        }
        cell.needsLayout = true
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !syncing, let n = notification.userInfo?["NSObject"] as? TabNode else { return }
        n.collapsed = false
        reload(node: n)
        owner.browser.markSessionDirty()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !syncing, let n = notification.userInfo?["NSObject"] as? TabNode else { return }
        n.collapsed = true
        reload(node: n)
        owner.browser.markSessionDirty()
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? TabNode else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) || flags.contains(.shift) { return } // building a selection
        if n.isFolder { return }
        owner.activate(owner.tab(n))
    }

    @objc private func rowDoubleClicked() {
        let row = outline.clickedRow
        if row < 0 { owner.newTab(); return }
        guard let n = outline.item(atRow: row) as? TabNode, n.isFolder else { return }
        if let first = n.subtree.first(where: { !$0.isFolder }) { owner.activate(owner.tab(first)) }
    }

    var selectedNodes: [TabNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? TabNode }
    }

    func activateSelection() {
        if let n = selectedNodes.first(where: { !$0.isFolder }) { owner.activate(owner.tab(n)); owner.focusContent() }
    }

    func closeSelection() {
        let nodes = selectedNodes
        for n in nodes where owner.tree.node(n.id) != nil { owner.close(node: n, subtree: false) }
    }

    // MARK: Rename folders inline

    func beginRename(_ folder: TabNode) {
        let row = outline.row(forItem: folder)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabCell else { return }
        renaming = folder
        cell.title.isEditable = true
        cell.title.delegate = self
        window?.makeFirstResponder(cell.title)
        cell.title.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let n = renaming else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { n.title = name }
        field.isEditable = false
        renaming = nil
        owner.browser.markSessionDirty()
        reload()
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? TabNode else {
            menu.addItem(ClosureMenuItem("New Tab") { [weak owner] in owner?.newTab() })
            return
        }
        var selection = selectedNodes
        if !selection.contains(where: { $0 === n }) { selection = [n] }
        contextMenu(for: n, selection: selection, into: menu)
    }

    func contextMenu(for n: TabNode, selection: [TabNode], into menu: NSMenu) {
        let o = owner
        if n.isFolder {
            menu.addItem(ClosureMenuItem("Rename") { [weak self] in self?.beginRename(n) })
            menu.addItem(ClosureMenuItem("Load All") { o.load(n) })
            menu.addItem(ClosureMenuItem("Unload All") { o.unload(n) })
            menu.addItem(ClosureMenuItem("Ungroup") { o.ungroup(n) })
        } else {
            let t = o.tab(n)
            menu.addItem(ClosureMenuItem("Reload") { t.reload(fromOrigin: false) })
            menu.addItem(ClosureMenuItem("Duplicate") { o.duplicate(t) })
            menu.addItem(ClosureMenuItem(o.tree.isPinned(n) ? "Unpin" : "Pin") { o.togglePin(t) })
            if o.browser.settings.tabs.favorites, n.url != nil {
                let isFavorite = o.browser.bookmarks.flattened().contains { $0.url == n.url?.absoluteString && $0.favorite }
                menu.addItem(ClosureMenuItem(isFavorite ? "Remove from Favorites" : "Add to Favorites") { o.toggleFavorite(n) })
            }
            if o.browser.settings.tabs.splitView {
                if o.isSplitMember(n) { menu.addItem(ClosureMenuItem("Exit Split") { o.exitSplit() }) }
                else if o.active !== t, o.workspaceID(of: n) == o.workspaceID {
                    menu.addItem(ClosureMenuItem("Split with Active Tab") { o.split(with: n) })
                }
            }
            menu.addItem(ClosureMenuItem(t.muted ? "Unmute" : "Mute") { t.toggleMute() })
            if t.isLoaded, o.active !== t { menu.addItem(ClosureMenuItem("Unload") { o.unload(n) }) }
            let containers = NSMenu()
            for c in o.browser.workspaces.containers {
                containers.addItem(ClosureMenuItem(c.name, state: o.container(for: n).id == c.id ? .on : .off) {
                    o.move(t, toContainer: c.id)
                })
            }
            let ci = NSMenuItem(title: "Move to Container", action: nil, keyEquivalent: "")
            ci.submenu = containers
            menu.addItem(ci)
            if let url = n.url, url.scheme == "http" || url.scheme == "https" {
                let engines = NSMenu()
                for e in Handoff.installed { engines.addItem(ClosureMenuItem(e.name) { Task { _ = await Handoff.open(url, in: e) } }) }
                let ei = NSMenuItem(title: "Open in", action: nil, keyEquivalent: "")
                ei.submenu = engines
                if !Handoff.installed.isEmpty { menu.addItem(ei) }
            }
        }
        let spaces = NSMenu()
        for w in o.browser.workspaces.workspaces {
            spaces.addItem(ClosureMenuItem(w.name, state: w.id == o.workspaceID ? .on : .off, enabled: w.id != o.workspaceID) {
                for s in selection { o.move(s, toWorkspace: w.id) }
            })
        }
        let si = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        si.submenu = spaces
        menu.addItem(si)
        menu.addItem(.separator())
        if !o.tree.isPinned(n) {
            menu.addItem(ClosureMenuItem(selection.count > 1 ? "Group \(selection.count) into Folder" : "Group into Folder", key: "") {
                o.group(selection)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(n.isFolder ? "Close Folder (keep tabs)" : "Close") {
            for s in selection { if o.tree.node(s.id) != nil { o.close(node: s, subtree: false) } }
        })
        if !n.children.isEmpty || n.isFolder {
            menu.addItem(ClosureMenuItem("Close with Children") { o.close(node: n, subtree: true) })
        }
        if !n.isFolder { menu.addItem(ClosureMenuItem("Close Others") { o.closeOthers(n) }) }
    }
}

// MARK: - Outline pieces

/// Keyboard: Return activates, Delete closes, Esc returns to content; ⌘G groups, ⇧⌘G ungroups;
/// middle-click closes.
final class TabOutlineView: NSOutlineView {
    weak var owner: BrowserWindowController?
    weak var sidebar: SidebarView?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: MainActor.assumeIsolated { sidebar?.activateSelection() }
        case 51, 117: MainActor.assumeIsolated { sidebar?.closeSelection() }
        case 53: MainActor.assumeIsolated { owner?.focusContent() }
        case 49: MainActor.assumeIsolated { sidebar?.activateSelection() }
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.charactersIgnoringModifiers?.lowercased() == "g",
              event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        return MainActor.assumeIsolated {
            guard let sidebar, let owner else { return false }
            if event.modifierFlags.contains(.shift) {
                for n in sidebar.selectedNodes where n.isFolder { owner.ungroup(n) }
            } else {
                owner.group(sidebar.selectedNodes)
            }
            return true
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard event.buttonNumber == 2, row >= 0, let n = item(atRow: row) as? TabNode else {
            super.otherMouseDown(with: event); return
        }
        MainActor.assumeIsolated { owner?.close(node: n, subtree: false) }
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var r = super.frameOfOutlineCell(atRow: row)
        r.origin.x = max(0, r.origin.x - 2)
        return r
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}

final class TabRowView: NSTableRowView {
    var style: Style?
    var isActiveTab = false
    /// The other visible pane of a split: shown, not focused.
    var isSplitPartner = false
    var containerColor: NSColor?
    private var hovering = false {
        didSet { (view(atColumn: 0) as? TabCell)?.hovering = hovering; needsDisplay = true }
    }

    override var isEmphasized: Bool { get { false } set {} }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let s = style else { return }
        if isActiveTab {
            s.selected.setFill(); bounds.fill()
            s.accent.setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        } else if isSplitPartner {
            s.selected.setFill(); bounds.fill()
            s.muted.setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        } else if hovering {
            s.raised.setFill(); bounds.fill()
        }
        if let c = containerColor, !isActiveTab { c.setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill() }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let s = style else { return }
        if isActiveTab { drawBackground(in: dirtyRect); return }
        s.raised.setFill(); bounds.fill()
        s.border.setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}

final class TabCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("TabCell")
    weak var sidebar: SidebarView?
    var node: TabNode?
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    let audio = NSImageView()
    let close = GlyphButton(size: 16)
    var hovering = false { didSet { needsLayout = true } }

    init() {
        super.init(frame: .zero)
        identifier = TabCell.id
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        title.isBordered = false
        title.drawsBackground = false
        title.focusRingType = .none
        badge.alignment = .right
        close.translatesAutoresizingMaskIntoConstraints = true
        icon.imageScaling = .scaleProportionallyDown
        for v: NSView in [icon, title, badge, audio, close] { addSubview(v) }
        textField = title
        imageView = icon
        close.action = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let n = self.node, let o = self.sidebar?.owner else { return }
                o.close(node: n, subtree: NSEvent.modifierFlags.contains(.option))
            }
        }
        close.toolTip = "Close (⌥ closes children)"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 2, y: (h - 14) / 2, width: 14, height: 14)
        let right: CGFloat = 20
        close.isHidden = !hovering
        close.frame = NSRect(x: bounds.width - right, y: (h - 16) / 2, width: 16, height: 16)
        badge.isHidden = hovering || badge.stringValue.isEmpty
        let bw: CGFloat = badge.isHidden ? 0 : 26
        badge.frame = NSRect(x: bounds.width - bw - 4, y: (h - 14) / 2, width: bw, height: 14)
        audio.frame = NSRect(x: bounds.width - right - bw - 14, y: (h - 12) / 2, width: 12, height: 12)
        let titleRight = hovering ? right + 2 : bw + 6 + (audio.isHidden ? 0 : 16)
        let th = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: 22, y: (h - th) / 2, width: max(0, bounds.width - 22 - titleRight), height: th)
    }
}

/// Horizontal two-finger swipes over the sidebar cycle workspaces.
final class SidebarScrollView: NSScrollView {
    weak var owner: BrowserWindowController?
    private var accum: CGFloat = 0
    private var fired = false

    override func scrollWheel(with event: NSEvent) {
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5
        if event.phase == .began { accum = 0; fired = false }
        guard horizontal || (accum != 0 && event.phase != .began) else { super.scrollWheel(with: event); return }
        guard event.phase != [] || event.momentumPhase == [] else { return }
        accum += event.scrollingDeltaX
        if !fired, abs(accum) >= 40 {
            fired = true
            let delta = accum > 0 ? -1 : 1
            MainActor.assumeIsolated { owner?.cycleWorkspace(by: delta) }
        }
        if event.phase == .ended || event.phase == .cancelled { accum = 0 }
    }
}

// MARK: - Workspace squares

final class WorkspaceStrip: NSView, NSViewToolTipOwner {
    unowned let owner: BrowserWindowController
    private var dropIndex: Int?
    private let size: CGFloat = 12, gap: CGFloat = 6, left: CGFloat = 8

    init(owner: BrowserWindowController) {
        self.owner = owner
        super.init(frame: .zero)
        registerForDraggedTypes([.anglTab])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var workspaces: [Workspace] { MainActor.assumeIsolated { owner.browser.workspaces.workspaces } }

    private func rect(_ i: Int) -> NSRect {
        NSRect(x: left + CGFloat(i) * (size + gap), y: (bounds.height - size) / 2, width: size, height: size)
    }

    private func index(at p: NSPoint) -> Int? {
        let i = Int((p.x - left + gap / 2) / (size + gap))
        return i >= 0 && i <= workspaces.count ? i : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated {
            let s = owner.style
            let all = workspaces
            for (i, w) in all.enumerated() {
                let r = rect(i)
                let active = w.id == owner.workspaceID
                s.workspaceColor(w.color).withAlphaComponent(active || dropIndex == i ? 1 : 0.45).setFill()
                r.fill()
                if active || dropIndex == i {
                    s.primary.setStroke()
                    let p = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
                    p.lineWidth = 1
                    p.stroke()
                }
            }
            let box = rect(all.count)
            s.muted.setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
            // "+" glyph centred in the new-workspace square.
            let plus = NSBezierPath()
            let mid = box.minX + box.width / 2, midY = box.minY + box.height / 2, arm: CGFloat = 3
            plus.move(to: NSPoint(x: mid - arm, y: midY)); plus.line(to: NSPoint(x: mid + arm, y: midY))
            plus.move(to: NSPoint(x: mid, y: midY - arm)); plus.line(to: NSPoint(x: mid, y: midY + arm))
            plus.lineWidth = 1
            s.secondary.setStroke()
            plus.stroke()
            let name = owner.workspace.name
            let attrs: [NSAttributedString.Key: Any] = [.font: s.monoSmall, .foregroundColor: s.secondary]
            let x = rect(all.count).maxX + 10
            let size = (name as NSString).size(withAttributes: attrs)
            if bounds.width - x - 6 > 20 {
                (name as NSString).draw(with: NSRect(x: x, y: (bounds.height - size.height) / 2, width: bounds.width - x - 6, height: size.height),
                                        options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attrs)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
            if i == workspaces.count { owner.newWorkspace() } else { owner.switchWorkspace(index: i) }
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            let menu = NSMenu()
            let o = owner
            if let i = index(at: convert(event.locationInWindow, from: nil)), i < workspaces.count {
                let w = workspaces[i]
                menu.addItem(ClosureMenuItem("Switch to \(w.name)") { o.switchWorkspace(id: w.id) })
                menu.addItem(ClosureMenuItem("Delete \(w.name)", enabled: workspaces.count > 1) { o.deleteWorkspace(w.id) })
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuItem("New Space") { o.newWorkspace() })
            menu.addItem(ClosureMenuItem("Edit Spaces…") { o.openInternal(InternalPages.url("spaces")) })
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func mouseMoved(with event: NSEvent) {}

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let i = index(at: point) else { return "" }
        return i < workspaces.count ? "\(workspaces[i].name) (⌃\(i + 1))" : "New Space"
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let i = index(at: convert(sender.draggingLocation, from: nil))
        dropIndex = i.flatMap { $0 < workspaces.count ? $0 : nil }
        needsDisplay = true
        return dropIndex == nil ? [] : .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropIndex = nil; needsDisplay = true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { dropIndex = nil; needsDisplay = true }
        return MainActor.assumeIsolated {
            guard let i = dropIndex, let nodes = owner.sidebar?.draggedNodes(sender), !nodes.isEmpty else { return false }
            let id = workspaces[i].id
            for n in nodes { owner.move(n, toWorkspace: id) }
            return true
        }
    }
}

// MARK: - Pinned rows

/// Pinned tabs: titled rows like the tree's, above it, closed off by a hairline.
final class PinnedRows: NSView, NSViewToolTipOwner {
    unowned let owner: BrowserWindowController
    private var rowHeight: CGFloat { owner.style.row }

    init(owner: BrowserWindowController) {
        self.owner = owner
        super.init(frame: .zero)
        clipsToBounds = true
        registerForDraggedTypes([.anglTab])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var nodes: [TabNode] { owner.tree.pinned }

    func height(for width: CGFloat) -> CGFloat { nodes.isEmpty ? 0 : CGFloat(nodes.count) * rowHeight + 5 }

    private func rect(_ i: Int) -> NSRect {
        NSRect(x: 0, y: 2 + CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight)
    }

    private func node(at p: NSPoint) -> TabNode? {
        nodes.indices.first { rect($0).contains(p) }.map { nodes[$0] }
    }

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated {
            guard !nodes.isEmpty else { return }
            let s = owner.style
            for (i, n) in nodes.enumerated() {
                let r = rect(i)
                let t = owner.liveTab(n)
                let active = owner.active?.node === n
                if active {
                    s.selected.setFill(); r.fill()
                    s.accent.setFill(); NSRect(x: r.minX, y: r.minY, width: 2, height: r.height).fill()
                }
                let loaded = t?.isLoaded == true || active
                let img = t?.favicon ?? Tab.storedFavicon(for: n.url) ?? s.symbol("globe")?.tinted(s.muted)
                img?.draw(in: NSRect(x: 12, y: r.midY - 7, width: 14, height: 14), from: .zero, operation: .sourceOver,
                          fraction: loaded ? 1 : 0.55, respectFlipped: true, hints: nil)
                let attrs: [NSAttributedString.Key: Any] = [.font: s.ui, .foregroundColor: loaded ? s.primary : s.muted]
                let title = (t?.displayTitle ?? (n.title.isEmpty ? n.url.map(Omnibox.display) ?? "New Tab" : n.title)) as NSString
                let th = ceil(title.size(withAttributes: attrs).height)
                var titleRight: CGFloat = 8
                if let t, t.muted || t.isPlaying,
                   let glyph = s.symbol(t.muted ? "speaker.slash" : "speaker.wave.2", size: 10)?.tinted(s.muted) {
                    glyph.draw(in: NSRect(x: r.maxX - 22, y: r.midY - 6, width: 12, height: 12), from: .zero,
                               operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    titleRight = 26
                }
                title.draw(with: NSRect(x: 32, y: r.midY - th / 2, width: max(0, r.width - 32 - titleRight), height: th),
                           options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            }
            s.border.setFill()
            NSRect(x: 8, y: bounds.height - 2, width: bounds.width - 16, height: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let n = node(at: convert(event.locationInWindow, from: nil)) else { return }
            owner.activate(owner.tab(n))
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard event.buttonNumber == 2, let n = node(at: convert(event.locationInWindow, from: nil)) else { return }
            owner.close(node: n, subtree: false)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let n = node(at: convert(event.locationInWindow, from: nil)), let sb = owner.sidebar else { return }
            let menu = NSMenu()
            sb.contextMenu(for: n, selection: [n], into: menu)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        node(at: point).map { owner.tab($0).displayTitle } ?? ""
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .move }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let nodes = owner.sidebar?.draggedNodes(sender) else { return false }
            for n in nodes where !n.isFolder { owner.tree.pin(n) }
            owner.sidebar?.reload()
            owner.browser.markSessionDirty()
            return true
        }
    }
}

/// Favourite bookmarks as icons; a click reuses the Space's matching tab or opens one.
final class FavoriteStrip: NSView, NSViewToolTipOwner {
    unowned let owner: BrowserWindowController
    init(owner: BrowserWindowController) { self.owner = owner; super.init(frame: .zero); clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var bookmarks: [Bookmark] { owner.browser.bookmarks.favorites() }
    private func rect(_ i: Int) -> NSRect { NSRect(x: 6 + CGFloat(i) * 26, y: 2, width: 24, height: 24) }
    private func index(at p: NSPoint) -> Int? {
        let items = bookmarks
        return items.indices.first { rect($0).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated {
            let style = owner.style
            for (index, bookmark) in bookmarks.enumerated() {
                let r = rect(index)
                let image = bookmark.url.flatMap(URL.init(string:)).flatMap(Tab.storedFavicon(for:))
                    ?? style.symbol("bookmark")?.tinted(style.secondary)
                image?.draw(in: NSRect(x: r.midX - 7, y: r.midY - 7, width: 14, height: 14),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            let items = bookmarks
            guard let i = index(at: convert(event.locationInWindow, from: nil)),
                  let url = items[i].url.flatMap(URL.init(string:)) else { return }
            let containerID = owner.active?.node.containerID
            if let match = owner.tree.allTabs.first(where: { $0.url == url && $0.containerID == containerID }) {
                owner.activate(owner.tab(match))
            } else {
                let node = TabNode.tab(url, containerID: containerID)
                owner.tree.insert(node)
                owner.activate(owner.tab(node))
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            let items = bookmarks
            guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
            NSMenu.popUpContextMenu(BookmarkMenu.make(items[i], owner), with: event, for: self)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated {
            let items = bookmarks
            return index(at: point).map { items[$0].title.isEmpty ? items[$0].url ?? "" : items[$0].title } ?? ""
        }
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }
}

/// Right-click menu for one bookmark: ⌘T/⌘L suggestion rows and the Favorites strip.
@MainActor
enum BookmarkMenu {
    static func make(_ bookmark: Bookmark, _ w: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        guard let link = bookmark.url, let url = URL(string: link) else { return menu }
        let browser = w.browser
        menu.addItem(ClosureMenuItem("Open in New Tab") { w.go(url, disposition: .newTab) })
        menu.addItem(ClosureMenuItem("Open in New Window") { w.go(url, disposition: .newWindow) })
        if browser.settings.tabs.splitView, w.active != nil {
            menu.addItem(ClosureMenuItem("Open in Split View") {
                let t = w.openTab(url, activate: false)
                if t !== w.active { w.split(with: t.node) }
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        })
        if browser.settings.tabs.favorites {
            menu.addItem(ClosureMenuItem(bookmark.favorite ? "Remove from Favorites" : "Add to Favorites") {
                change(bookmark, w) { $0.favorite.toggle() }
            })
        }
        menu.addItem(ClosureMenuItem("Edit Bookmark…") { edit(bookmark, w) })
        menu.addItem(ClosureMenuItem("Delete Bookmark") {
            var store = browser.bookmarks
            store.remove(id: bookmark.id)
            browser.setBookmarks(store)
        })
        return menu
    }

    private static func change(_ bookmark: Bookmark, _ w: BrowserWindowController, _ f: (inout Bookmark) -> Void) {
        var store = w.browser.bookmarks
        store.update(id: bookmark.id, f)
        w.browser.setBookmarks(store)
    }

    /// Title and address in one sheet; an empty or unparsable address keeps the old one.
    private static func edit(_ bookmark: Bookmark, _ w: BrowserWindowController) {
        guard let window = w.window else { return }
        let title = NSTextField(frame: NSRect(x: 0, y: 30, width: 360, height: 22))
        let address = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
        title.stringValue = bookmark.title
        address.stringValue = bookmark.url ?? ""
        title.placeholderString = "Title"
        address.placeholderString = "Address"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 52))
        fields.addSubview(title)
        fields.addSubview(address)
        let alert = NSAlert()
        alert.messageText = "Edit Bookmark"
        alert.accessoryView = fields
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = title
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                let typed = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = URL(string: typed).flatMap { $0.scheme == nil ? nil : $0.absoluteString }
                change(bookmark, w) {
                    $0.title = title.stringValue
                    if let url { $0.url = url }
                }
            }
        }
    }
}

// MARK: - Downloads footer

final class DownloadsFooter: FlatView {
    unowned let owner: BrowserWindowController
    private let text = NSTextField(labelWithString: "")
    private let bar = FlatView()
    private var flashUntil = Date.distantPast
    private var lastActive = 0

    init(owner: BrowserWindowController) {
        self.owner = owner
        super.init(frame: .zero)
        addSubview(text)
        addSubview(bar)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyStyle() {
        MainActor.assumeIsolated {
            let s = owner.style
            fill = s.sidebar
            borderColor = s.border
            edges = .top
            text.font = s.monoSmall
            bar.fill = s.accent
        }
    }

    func update() {
        MainActor.assumeIsolated {
            let d = owner.browser.downloads
            let active = d.active
            if active.count < lastActive { flashUntil = Date().addingTimeInterval(3) }
            lastActive = active.count
            let s = owner.style
            if !active.isEmpty {
                let got = active.map(\.received).reduce(0, +), total = active.map(\.total).reduce(0, +)
                let frac = total > 0 ? Double(got) / Double(total) : 0
                text.stringValue = "↓ \(active.count) · \(total > 0 ? "\(Int(frac * 100))%" : ByteCountFormatter.string(fromByteCount: got, countStyle: .file))"
                text.textColor = s.secondary
                bar.isHidden = false
                bar.frame = NSRect(x: 0, y: bounds.height - 2, width: bounds.width * frac, height: 2)
                isHidden = false
            } else if Date() < flashUntil {
                text.stringValue = "↓ done · \(d.items.first?.filename ?? "")"
                text.textColor = s.ok
                bar.isHidden = true
                isHidden = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.owner.sidebar?.updateFooter() }
            } else {
                isHidden = true
            }
        }
    }

    override func layout() {
        super.layout()
        let th = ceil(text.intrinsicContentSize.height)
        text.frame = NSRect(x: 8, y: (bounds.height - th) / 2, width: bounds.width - 16, height: th)
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { owner.openInternal(InternalPages.url("downloads")) }
    }
}
