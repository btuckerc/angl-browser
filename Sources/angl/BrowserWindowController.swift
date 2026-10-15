import AnglCore
import AppKit
import WebKit

/// One browser window: a tab tree per workspace, the nav bar, the sidebar and the content area.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let browser: Browser
    private(set) var trees: [UUID: TabTree] = [:]
    private var activeByWorkspace: [UUID: UUID] = [:]
    private(set) var workspaceID: UUID
    private var tabs: [UUID: Tab] = [:]
    private(set) var active: Tab?

    private struct SplitState {
        var first: UUID
        var second: UUID
        var focused: UUID
        var ratio: CGFloat
        var saved: SavedSplit {
            SavedSplit(firstTab: first, secondTab: second, focusedTab: focused, ratio: Double(ratio))
        }
    }
    private var splits: [UUID: SplitState] = [:]
    private var storedSplits: [UUID: SavedSplit] = [:]
    /// The split view setting as last applied, to notice it being switched off.
    private var splitViewShown = Browser.shared.settings.tabs.splitView
    private(set) var sidebarHidden: Bool
    private(set) var sidebarWidth: CGFloat
    private(set) var focusMode = false
    private var peeking = false
    private var navForcedVisible = false

    let root = RootView()
    private(set) var navBar: NavBar!
    private(set) var sidebar: SidebarView!
    let content = FlatView()
    private let splitDivider = SplitDivider()
    private let paneMarker = PaneOutline()
    private let progressLine = FlatView()
    private var blank: BlankView!
    private(set) var findBar: FindBar!
    private let permissionBar = PermissionBar()
    private let status = StatusOverlay()
    private let edge = EdgeTrigger()
    private let resizeHandle = ResizeHandle()
    private let contentFrame = ContentFrameView()
    private var sitePanel: SitePanel?
    private var notes: [NSObjectProtocol] = []
    private var peekTimer: Timer?

    private(set) var palette: PalettePanel!
    var paletteMode: Bool { browser.theme.window.address == .palette }
    var siteButtonRectOnScreen: NSRect { paletteMode ? sidebar.siteButtonRectOnScreen : navBar.siteButtonRectOnScreen }
    var style: Style { browser.style }
    var workspace: Workspace { browser.workspaces.workspace(workspaceID) ?? browser.workspaces.workspaces[0] }
    var tree: TabTree { treeFor(workspaceID) }
    var findVisible: Bool { !findBar.isHidden }
    var canReopen: Bool { browser.history?.latestClosedRecovery() != nil }

    init(browser: Browser, saved: SavedWindow?) {
        self.browser = browser
        let cfg = browser.workspaces
        workspaceID = saved.flatMap { s in cfg.workspace(s.activeWorkspace)?.id } ?? cfg.workspaces[0].id
        sidebarHidden = saved?.sidebarHidden ?? (browser.theme.sidebar.mode == .hidden)
        sidebarWidth = CGFloat(saved?.sidebarWidth ?? browser.theme.metrics.sidebarWidth)

        let window = AnglWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 480, height: 320)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        root.controller = self
        navBar = NavBar(owner: self)
        sidebar = SidebarView(owner: self)
        palette = PalettePanel(owner: self)
        blank = BlankView(owner: self)
        findBar = FindBar(owner: self)
        for v: NSView in [content, sidebar, navBar, findBar, permissionBar, edge, resizeHandle, contentFrame] { root.addSubview(v) }
        content.addSubview(blank)
        content.addSubview(status)
        content.addSubview(progressLine)
        findBar.isHidden = true
        permissionBar.isHidden = true
        edge.onEnter = { [weak self] in self?.schedulePeek(true) }
        edge.onExit = { [weak self] in self?.peekTimer?.invalidate() }
        sidebar.onExit = { [weak self] in self?.schedulePeek(false) }
        sidebar.onEnter = { [weak self] in self?.peekTimer?.invalidate() }
        resizeHandle.onDrag = { [weak self] dx in self?.resizeSidebar(by: dx) }
        splitDivider.onDrag = { [weak self] dx in self?.resizeSplit(by: dx) }

        if let saved {
            for t in saved.trees where cfg.workspace(t.workspaceID) != nil {
                trees[t.workspaceID] = t.makeTree()
                if let a = t.activeTab { activeByWorkspace[t.workspaceID] = a }
            }
            for savedTree in saved.trees {
                if let s = savedTree.split { storedSplits[savedTree.workspaceID] = s }
                guard browser.settings.tabs.splitView,
                      let s = savedTree.split, let tr = trees[savedTree.workspaceID],
                      s.firstTab != s.secondTab, tr.node(s.firstTab) != nil, tr.node(s.secondTab) != nil else { continue }
                let focused = s.focusedTab == s.secondTab ? s.secondTab : s.firstTab
                splits[savedTree.workspaceID] = SplitState(first: s.firstTab, second: s.secondTab,
                                                             focused: focused, ratio: CGFloat(min(0.8, max(0.2, s.ratio))))
                activeByWorkspace[savedTree.workspaceID] = focused
            }

            if let f = saved.frame { window.setFrame(NSRectFromString(f), display: false) } else { window.center() }
        } else {
            window.center()
        }
        observe()
        applyStyle()
        showWorkspace(workspaceID)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func observe() {
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, _ f: @escaping @MainActor (BrowserWindowController) -> Void) {
            notes.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { f(self) } }
            })
        }
        on(.anglTheme) { $0.applyStyle() }
        on(.anglSettings) { w in
            // Turning split view off hides the unfocused pane: its idle clock starts now.
            let splitView = w.browser.settings.tabs.splitView
            if w.splitViewShown, !splitView { w.stampSplitPanes(in: w.workspaceID) }
            w.splitViewShown = splitView
            w.refreshContentPolicies()
            w.attachActive()
            w.sidebar.reload()
        }
        on(.anglUserCSS) { $0.refreshContentPolicies() }
        on(.anglSites) { w in w.active?.invalidatePolicy(); w.navBar.update() }
        on(.anglWorkspaces) { $0.workspacesChanged() }
        on(.anglDownloads) { $0.sidebar.updateFooter() }
        on(.anglBookmarks) { w in
            w.sidebar.reload()
            w.palette.bookmarksChanged()
            w.blank.bookmarksChanged()
            w.navBar.bookmarksChanged()
        }
    }

    // MARK: Tabs

    func treeFor(_ ws: UUID) -> TabTree {
        if let t = trees[ws] { return t }
        let t = TabTree()
        trees[ws] = t
        return t
    }

    func tab(_ node: TabNode) -> Tab {
        if let t = tabs[node.id] { return t }
        let t = Tab(node: node, owner: self)
        tabs[node.id] = t
        return t
    }

    func liveTab(_ node: TabNode) -> Tab? { tabs[node.id] }

    func workspaceID(of node: TabNode) -> UUID? {
        trees.first { $0.value.node(node.id) != nil }?.key
    }

    func container(for node: TabNode) -> Container {
        let ws = workspaceID(of: node).flatMap { browser.workspaces.workspace($0) } ?? workspace
        return browser.container(for: node, in: ws)
    }

    /// New top-level tab at the end of the current workspace.
    @discardableResult
    func openTab(_ url: URL?, activate: Bool) -> Tab {
        if let url, let a = active, a.url == nil, !a.isLoaded {
            a.navigate(url)
            if activate {
                self.activate(a)
                if !navBar.typed { focusContent() }
            }
            return a
        }
        let node = TabNode.tab(url)
        tree.insert(node)
        let t = tab(node)
        if activate { self.activate(t) } else if url != nil { t.load() }
        sidebar.reload()
        browser.markSessionDirty()
        return t
    }

    /// Cmd-T: start a new-tab palette without creating an uncommitted blank tab.
    func newTab() {
        if paletteMode { openAddressPalette(prefill: nil, newTab: true); return }
        if let a = active, a.url == nil, !a.isLoaded { focusURLField(); return }
        _ = openTab(nil, activate: true)
        focusURLField()
    }

    /// A tab opened from `parent` becomes its last child (window.open, Cmd-click, context menu).
    @discardableResult
    func openChild(of parent: Tab, url: URL?, configuration: WKWebViewConfiguration?, activate: Bool,
                   containerID: UUID? = nil) -> Tab {
        let node = TabNode.tab(url, containerID: containerID ?? parent.node.containerID)
        let ws = workspaceID(of: parent.node) ?? workspaceID
        let t = treeFor(ws)
        if t.isPinned(parent.node) { t.insert(node) } else { t.insert(node, under: parent.node) }
        parent.node.collapsed = false
        let child = tab(node)
        if let configuration {
            child.makeWebView(configuration: configuration)
        } else if let url, !activate {
            child.navigate(url)
        }
        if activate { self.activate(child) }
        sidebar.reload()
        browser.markSessionDirty()
        return child
    }

    @discardableResult
    func openChild(of parent: Tab, url: URL, containerID: UUID) -> Tab {
        let ws = workspaceID(of: parent.node).flatMap { browser.workspaces.workspace($0) } ?? workspace
        return openChild(of: parent, url: url, configuration: nil, activate: false,
                         containerID: containerID == ws.containerID ? nil : containerID)
    }

    func activate(_ t: Tab) {
        if let ws = workspaceID(of: t.node), ws != workspaceID { switchWorkspace(id: ws, activating: t); return }
        let previous = active
        if let previous, previous !== t { Passwords.shared.pageHidden(in: previous) }
        previous?.node.lastActive = Date()
        stampSplitPanes(in: workspaceID)
        if browser.settings.tabs.splitView, var split = splits[workspaceID], t.node.id != split.first, t.node.id != split.second {
            if split.focused == split.first { split.first = t.node.id } else { split.second = t.node.id }
            splits[workspaceID] = split
        }
        active = t
        activeByWorkspace[workspaceID] = t.node.id
        if var split = splits[workspaceID], t.node.id == split.first || t.node.id == split.second {
            split.focused = t.node.id
            splits[workspaceID] = split
            storedSplits[workspaceID] = split.saved
        }
        t.node.lastActive = Date()
        var a = t.node.parent
        while let n = a { n.collapsed = false; a = n.parent }
        if t.url != nil { t.load() }
        if let s = splits[workspaceID], let other = tree.node(s.focused == s.first ? s.second : s.first) {
            let otherTab = tab(other)
            if otherTab.url != nil { otherTab.load() }
        }
        attachActive()
        if previous !== t, navBar.editing, !navBar.typed, let wv = t.webView { window?.makeFirstResponder(wv) }
        sidebar.reload()
        sitePanel?.close()
        if !findBar.isHidden { findBar.isHidden = true; root.needsLayout = true }
        browser.markSessionDirty()
    }

    func split(with node: TabNode) {
        guard browser.settings.tabs.splitView, node.id != active?.node.id,
              workspaceID(of: node) == workspaceID, let active else { return }
        stampSplitPanes(in: workspaceID)
        let split = SplitState(first: active.node.id, second: node.id, focused: active.node.id, ratio: 0.5)
        splits[workspaceID] = split
        storedSplits[workspaceID] = split.saved
        tab(node).load()
        attachActive()
        sidebar.reload()
        browser.markSessionDirty()
    }

    func toggleSplitChooser() {
        guard browser.settings.tabs.splitView else { return }
        if splits[workspaceID] != nil { exitSplit() } else { palette.showTabChooser() }
    }

    func exitSplit() {
        guard browser.settings.tabs.splitView, splits[workspaceID] != nil else { return }
        stampSplitPanes(in: workspaceID)
        splits[workspaceID] = nil
        storedSplits[workspaceID] = nil
        attachActive()
        root.needsLayout = true
        sidebar.reload()
        browser.markSessionDirty()
    }

    func focusSplitPane(left: Bool) {
        guard browser.settings.tabs.splitView, let split = splits[workspaceID] else { return }
        let id = left ? split.first : split.second
        guard let node = tree.node(id) else { return }
        activate(tab(node))
    }

    /// Split panes are visible without being active; the memory saver's idle clock starts when they leave view.
    private func stampSplitPanes(in ws: UUID) {
        guard let s = splits[ws], let tr = trees[ws] else { return }
        let now = Date()
        for id in [s.first, s.second] { tr.node(id)?.lastActive = now }
    }

    var isSplit: Bool { browser.settings.tabs.splitView && splits[workspaceID] != nil }

    func webViewCreated(for t: Tab) {
        if t === active || isSplitMember(t.node) { attachActive() }
    }

    func isSplitMember(_ node: TabNode) -> Bool {
        guard browser.settings.tabs.splitView,
              let ws = workspaceID(of: node), let split = splits[ws] else { return false }
        return node.id == split.first || node.id == split.second
    }

    private func splitMembers(in ws: UUID) -> Set<UUID> {
        guard let split = splits[ws] else { return [] }
        return [split.first, split.second]
    }

    func resizeSplit(by delta: CGFloat) {
        guard var s = splits[workspaceID] else { return }
        s.ratio = min(0.8, max(0.2, s.ratio + delta / max(1, content.bounds.width)))
        splits[workspaceID] = s
        storedSplits[workspaceID] = s.saved
        root.needsLayout = true
        browser.markSessionDirty()
    }


    private func attachActive() {
        let split = browser.settings.tabs.splitView ? splits[workspaceID] : nil
        let members = split.map { [$0.first, $0.second] } ?? active.map { [$0.node.id] } ?? []
        for (id, t) in tabs {
            guard members.contains(id), let wv = t.webView else { t.webView?.removeFromSuperview(); continue }
            if wv.superview !== content { content.addSubview(wv, positioned: .below, relativeTo: status) }
            wv.autoresizingMask = []
            wv.onPaneFocus = { [weak self, weak t] in
                guard let self, let t, t !== self.active else { return }
                self.activate(t)
            }
        }
        blank.isHidden = active?.webView != nil
        splitDivider.isHidden = split == nil
        layoutContentPanes()
        // Hand the keyboard over unless something else (sidebar, find bar) holds it; a hidden docked field doesn't count.
        let free = window?.firstResponder === window || window?.firstResponder == nil || (blank.isHidden && blank.holdsKeyboard)
        if free { if let wv = active?.webView { window?.makeFirstResponder(wv) } else { blank.takeKeyboard() } }
    }


    private func collapseSplit(containing ids: Set<UUID>, workspace ws: UUID) {
        guard let split = splits[ws], ids.contains(split.first) || ids.contains(split.second) else { return }
        let survivorID = ids.contains(split.first) ? split.second : split.first
        stampSplitPanes(in: ws)
        splits[ws] = nil
        storedSplits[ws] = nil
        if ws == workspaceID, let survivor = tree.node(survivorID) {
            if let previous = active, previous !== tab(survivor) { Passwords.shared.pageHidden(in: previous) }
            active = tab(survivor)
            activeByWorkspace[ws] = survivorID
        }
        attachActive()
    }


    func focusContent() {
        if let wv = active?.webView { window?.makeFirstResponder(wv) }
        else if !paletteMode { focusURLField() }
        else { blank.takeKeyboard() }
    }

    func close(_ t: Tab, subtree: Bool) {
        guard let ws = workspaceID(of: t.node) else { return }
        let tr = treeFor(ws)
        let wasActive = t === active
        let closing = Set((subtree ? t.node.subtree : [t.node]).map(\.id))
        // Closing one split pane leaves the other pane as the active tab.
        let partner = splits[ws].flatMap { s in [s.first, s.second].first { !closing.contains($0) && closing.contains(s.first == $0 ? s.second : s.first) } }
        let next = wasActive ? (partner.flatMap(tr.node) ?? tr.successor(of: t.node, closingSubtree: subtree)) : nil
        collapseSplit(containing: closing, workspace: ws)
        t.captureState()
        let parent = t.node.parent
        let index = parent?.children.firstIndex { $0 === t.node } ?? 0
        if t.url != nil {
            var saved = SavedNode(t.node)
            if !subtree { saved.children = nil }
            let record = RecoveryRecord(saved: saved, workspaceID: ws,
                                        parentID: parent === tr.root ? nil : parent?.id,
                                        index: index, reason: .closed)
            try? browser.history?.addRecovery(record)
        }
        let removed = subtree ? tr.removeSubtree(t.node) : tr.remove(t.node)
        for n in removed { if let x = tabs.removeValue(forKey: n.id) { x.unload() } }
        if wasActive {
            if let next { activate(tab(next)) }
            else if paletteMode { active = nil; attachActive(); openAddressPalette(prefill: nil, newTab: true) }
            else { openTab(nil, activate: true); focusURLField() }
        }
        sidebar.reload()
        browser.markSessionDirty()
    }

    func closeActive(subtree: Bool) {
        if let a = active { close(a, subtree: subtree) }
        // ⌘W with no page left in any Space (uncommitted blank tabs don't count): close the window.
        if browser.settings.tabs.closeWindowWithLastTab, trees.values.allSatisfy({ $0.allTabs.allSatisfy { $0.url == nil } }) {
            window?.performClose(nil)
        }
    }

    func close(node: TabNode, subtree: Bool) {
        if node.isFolder {
            let tr = tree
            for n in (subtree ? node.subtree : [node]) where !n.isFolder { tabs.removeValue(forKey: n.id)?.unload() }
            let activeGone = active.map { a in subtree && node.isAncestor(of: a.node) } ?? false
            let next = activeGone ? tr.successor(of: node, closingSubtree: true) : nil
            subtree ? _ = tr.removeSubtree(node) : tr.ungroup(node)
            if activeGone {
                active = nil
                if let next { activate(tab(next)) }
                else if paletteMode { attachActive(); openAddressPalette(prefill: nil, newTab: true) }
                else { openTab(nil, activate: true) }
            }
            browser.markSessionDirty()
        } else {
            close(tab(node), subtree: subtree)
        }
    }

    func reopenClosed() {
        guard let record = browser.history?.latestClosedRecovery() else { return }
        guard restore(record) else { return }
        _ = browser.history?.deleteRecovery(id: record.id)
    }
    func restore(_ record: RecoveryRecord) -> Bool {
        let ws = browser.workspaces.workspace(record.workspaceID)?.id ?? workspaceID
        let tr = treeFor(ws)
        guard tr.node(record.saved.id) == nil else { return false }
        let parent = record.parentID.flatMap { tr.node($0) }.flatMap { $0.isFolder ? $0 : nil }
        let target = parent ?? tr.root
        record.saved.makeNode(into: tr, under: target === tr.root ? nil : target)
        guard let restored = tr.node(record.saved.id) else { return false }
        tr.insert(restored, under: target === tr.root ? nil : target, at: record.index)
        activate(tab(restored))
        sidebar.reload()
        browser.markSessionDirty()
        return true
    }


    func closeOthers(_ keep: TabNode) {
        for n in tree.allTabs where n !== keep && !tree.isPinned(n) { close(tab(n), subtree: false) }
    }

    /// Visible tabs in sidebar order (pinned, then tree).
    private var orderedTabs: [TabNode] {
        tree.pinned + tree.root.children.flatMap(\.subtree).filter { !$0.isFolder }
    }

    func selectTab(offset: Int) {
        let all = orderedTabs
        guard !all.isEmpty else { return }
        let i = active.flatMap { a in all.firstIndex { $0 === a.node } } ?? 0
        activate(tab(all[(i + offset + all.count) % all.count]))
    }

    func selectTab(index: Int) {
        let all = orderedTabs
        guard !all.isEmpty else { return }
        let i = index < 0 ? all.count - 1 : index
        if i < all.count { activate(tab(all[i])) }
    }

    func selectParent() {
        var p = active?.node.parent
        while let n = p, n.isFolder { p = n.parent }
        if let p, p !== tree.root { activate(tab(p)) }
    }

    func selectFirstChild() {
        if let c = active?.node.children.lazy.compactMap({ $0.subtree.first { !$0.isFolder } }).first { activate(tab(c)) }
    }

    func togglePin(_ t: Tab) {
        let tr = treeFor(workspaceID(of: t.node) ?? workspaceID)
        tr.isPinned(t.node) ? tr.unpin(t.node) : tr.pin(t.node)
        sidebar.reload()
        browser.markSessionDirty()
    }

    func duplicate(_ t: Tab) {
        t.captureState()
        let node = TabNode(kind: .tab, title: t.node.title, url: t.url, containerID: t.node.containerID,
                           interactionState: t.node.interactionState)
        let tr = treeFor(workspaceID(of: t.node) ?? workspaceID)
        if tr.isPinned(t.node) { tr.insert(node) } else { tr.insert(node, after: t.node) }
        activate(tab(node))
    }

    func unloadOthers() {
        let visible = isSplit ? splitMembers(in: workspaceID) : []
        for (id, t) in tabs where t !== active && t.isLoaded && !visible.contains(id) { t.unload() }
        sidebar.reload()
    }

    func unloadIdleTabs(before cutoff: Date) {
        var changed = false
        for (ws, tr) in trees {
            // Only the current Space's panes are on screen; a background Space's split ages normally.
            let visible = browser.settings.tabs.splitView && ws == workspaceID ? splitMembers(in: ws) : []
            for n in tr.allTabs where !tr.isPinned(n) && n.lastActive < cutoff {
                guard !visible.contains(n.id), let t = tabs[n.id], t.isLoaded,
                      t !== active, !t.protectsFromAutomaticRemoval else { continue }
                t.unload()
                changed = true
            }
        }
        if changed { sidebar.reload() }
    }
    func archiveIdleTabs(before cutoff: Date) {
        let candidates = trees.values.flatMap(\.allTabs).filter { $0.lastActive < cutoff }
        for node in candidates {
            guard let ws = workspaceID(of: node), let tr = trees[ws], !tr.isPinned(node),
                  !isSplitMember(node),
                  active?.node !== node, let url = node.url,
                  url.scheme != InternalPages.scheme, url.absoluteString != "about:blank",
                  tabs[node.id]?.protectsFromAutomaticRemoval != true,
                  browser.downloads.active.isEmpty else { continue }
            tabs[node.id]?.captureState()
            var saved = SavedNode(node)
            saved.children = nil
            let parent = node.parent
            let index = parent?.children.firstIndex { $0 === node } ?? 0
            let record = RecoveryRecord(saved: saved, workspaceID: ws,
                                        parentID: parent === tr.root ? nil : parent?.id,
                                        index: index, reason: .archived)
            guard let history = browser.history else { continue }
            do { try history.addRecovery(record) } catch { continue }
            _ = tr.remove(node)
            tabs.removeValue(forKey: node.id)?.unload()
            sidebar.reload()
            browser.markSessionDirty()
        }
    }

    func unload(_ node: TabNode) {
        let ids = Set(node.subtree.filter { !$0.isFolder }.map(\.id))
        collapseSplit(containing: ids, workspace: workspaceID(of: node) ?? workspaceID)
        for n in node.subtree where !n.isFolder {
            if let t = tabs[n.id], t !== active { t.unload() }
        }
        sidebar.reload()
    }

    func load(_ node: TabNode) {
        for n in node.subtree where !n.isFolder && n.url != nil { tab(n).load() }
        sidebar.reload()
    }

    func group(_ nodes: [TabNode]) {
        guard let folder = tree.group(nodes, name: "Folder") else { return }
        sidebar.reload()
        sidebar.beginRename(folder)
        browser.markSessionDirty()
    }

    func ungroup(_ folder: TabNode) {
        tree.ungroup(folder)
        sidebar.reload()
        browser.markSessionDirty()
    }

    /// Imported tabs: one folder in the current workspace, unloaded.
    func openFolder(named name: String, tabs list: [(URL, String)]) {
        let folder = TabNode(kind: .folder, title: name, collapsed: true)
        tree.insert(folder)
        for (u, title) in list { tree.insert(TabNode.tab(u, title: title), under: folder) }
        sidebar.reload()
        browser.markSessionDirty()
    }

    /// Changing a container means a new web view: data stores are fixed at creation.
    func move(_ t: Tab, toContainer id: UUID?) {
        let ws = workspaceID(of: t.node).flatMap { browser.workspaces.workspace($0) } ?? workspace
        let targetID = id ?? ws.containerID
        let newID: UUID? = id
        guard t.node.containerID != newID else { return }
        collapseSplit(containing: [t.node.id], workspace: ws.id)
        let url = t.url
        t.unload()
        t.node.containerID = newID
        t.node.interactionState = nil
        if let url { t.navigate(url) }
        if t === active { attachActive() }
        let name = browser.workspaces.container(targetID)?.name ?? "container"
        toast(id == nil ? "using Space default container (reloaded)" : "moved to \(name) (reloaded)", color: style.secondary)
        sidebar.reload()
        navBar.update()
        browser.markSessionDirty()
    }


    /// Move a subtree into another workspace (and so its container).
    func move(_ node: TabNode, toWorkspace ws: UUID) {
        guard let from = workspaceID(of: node), from != ws else { return }
        let oldTree = treeFor(from)
        let wasActive = active.map { node === $0.node || node.isAncestor(of: $0.node) } ?? false
        let next = wasActive ? oldTree.successor(of: node, closingSubtree: true) : nil
        collapseSplit(containing: Set(node.subtree.filter { !$0.isFolder }.map(\.id)), workspace: from)

        let moved = node.subtree.filter { !$0.isFolder }
        let oldContainers = moved.map { container(for: $0).id }
        if oldTree.isPinned(node) { oldTree.unpin(node) }
        oldTree.removeSubtree(node)
        treeFor(ws).insert(node)
        for (n, old) in zip(moved, oldContainers) where container(for: n).id != old {
            if let t = tabs[n.id], t.isLoaded { let u = t.url; t.unload(); n.interactionState = nil; if let u { t.navigate(u) } }
        }
        if wasActive {
            active?.webView?.removeFromSuperview()
            active = nil
            if let next { activate(tab(next)) } else { openTab(nil, activate: true) }
        }
        sidebar.reload()
        browser.markSessionDirty()
    }

    // MARK: Workspaces

    func switchWorkspace(index: Int) {
        let all = browser.workspaces.workspaces
        if all.indices.contains(index) { switchWorkspace(id: all[index].id) }
    }

    func cycleWorkspace(by delta: Int) {
        let all = browser.workspaces.workspaces
        guard let i = all.firstIndex(where: { $0.id == workspaceID }) else { return }
        switchWorkspace(id: all[(i + delta + all.count) % all.count].id)
    }

    func switchWorkspace(id: UUID, activating t: Tab? = nil) {
        if id == workspaceID, t == nil { return }
        if let previous = active {
            previous.node.lastActive = Date()
            Passwords.shared.pageHidden(in: previous)
        }
        stampSplitPanes(in: workspaceID)
        active?.webView?.removeFromSuperview()
        active = nil
        workspaceID = id
        showWorkspace(id, activating: t)
    }

    private func showWorkspace(_ id: UUID, activating t: Tab? = nil) {
        let tr = treeFor(id)
        if let t {
            activate(t)
        } else if let aid = activeByWorkspace[id], let n = tr.node(aid), !n.isFolder {
            activate(tab(n))
        } else if let n = tr.allTabs.first {
            activate(tab(n))
        } else if paletteMode {
            active = nil
            attachActive()
            openAddressPalette(prefill: nil, newTab: true)
        } else {
            openTab(nil, activate: true)
        }
        sidebar.reload()
        browser.markSessionDirty()
    }

    func newWorkspace() {
        var cfg = browser.workspaces
        let palette = browser.theme.color.workspaces
        let color = palette.first { c in !cfg.workspaces.contains { $0.color == c } } ?? palette[cfg.workspaces.count % palette.count]
        let n = cfg.workspaces.count + 1
        let w = Workspace(name: "Space \(n)", color: color, containerID: workspace.containerID)
        cfg.workspaces.append(w)
        browser.setWorkspaces(cfg)
        switchWorkspace(id: w.id)
    }

    func deleteWorkspace(_ id: UUID) {
        var cfg = browser.workspaces
        guard cfg.workspaces.count > 1 else { return }
        cfg.workspaces.removeAll { $0.id == id }
        browser.setWorkspaces(cfg)
    }

    private func workspacesChanged() {
        let cfg = browser.workspaces
        // Tabs of deleted workspaces move to the first workspace rather than vanish.
        for (id, tr) in trees where cfg.workspace(id) == nil {
            let target = treeFor(cfg.workspaces[0].id)
            for n in tr.pinned { target.pin(n) }
            for n in tr.root.children { target.insert(n) }
            trees[id] = nil
        }
        if cfg.workspace(workspaceID) == nil {
            active?.webView?.removeFromSuperview()
            active = nil
            workspaceID = cfg.workspaces[0].id
            showWorkspace(workspaceID)
        }
        // Tabs explicitly in a deleted container fall back to their Space's; container edits
        // (proxy, deletion) change which store a tab must use.
        let containerIDs = Set(cfg.containers.map(\.id))
        for tr in trees.values {
            for n in tr.allTabs where n.containerID.map({ !containerIDs.contains($0) }) ?? false { n.containerID = nil }
        }
        for (_, t) in tabs where t.isLoaded {
            if t.webView?.configuration.websiteDataStore !== browser.web.dataStore(for: t.container) {
                let u = t.url
                t.unload()
                if let u, t === active { t.navigate(u) }
            }
        }
        attachActive()
        sidebar.reload()
        navBar.update()
    }

    func workspaceClaiming(_ url: URL, from t: Tab) -> Workspace? {
        let current = workspaceID(of: t.node) ?? workspaceID
        guard browser.settings.tabs.routeByURL, t.node.containerID == nil else { return nil } // explicit container choice wins
        return browser.workspaces.workspace(claiming: url, current: current)
    }

    /// A URL rule claimed a navigation: reopen it in that workspace (fresh, GET only).
    func reopen(_ url: URL, in ws: Workspace, from t: Tab) {
        let fresh = t.webView?.backForwardList.currentItem == nil
        let node = TabNode.tab(url)
        treeFor(ws.id).insert(node)
        let nt = tab(node)
        if fresh { close(t, subtree: false) }
        switchWorkspace(id: ws.id, activating: nt)
        toast("opened in \(ws.name)", color: style.workspaceColor(ws.color))
    }

    // MARK: Callbacks from tabs

    func tabChanged(_ t: Tab) {
        sidebar.reload(node: t.node)
        if t === active { navBar.update() }
    }

    func progressChanged(_ t: Tab) {
        if t === active { navBar.updateProgress(); updateProgressLine() }
    }

    func navigationCommitted(in t: Tab) {
        guard t === active else { return }
        UserDefaults.standard.set(true, forKey: "angl.hintSeen")
        attachActive()
        status.show(nil, from: t)
        if let p = t.policy, !p.javascript, t.url?.scheme != InternalPages.scheme {
            status.flash("JavaScript off", color: style.muted)
        }
    }

    func showHover(_ url: URL?, from t: Tab) {
        guard t === active else { return }
        status.show(url.map { Omnibox.display($0) }, from: t)
    }

    func passkeyFailed(in t: Tab) {
        guard let url = t.url, let host = SiteStore.key(for: url), let safari = Engine.engine(id: "safari") else { return }
        Task { @MainActor in
            let i = await permissionBar.ask("passkeys need Safari (angl has no passkey entitlement)",
                                            buttons: ["Open in Safari", "Always for \(host)", "Dismiss"], owner: self)
            if i == 0 || i == 1 { _ = await Handoff.open(url, in: safari) }
            if i == 1 {
                var rules = browser.settings.engines.rules
                rules.append(EngineRule(match: URLRule(.host, host), engine: "safari"))
                try? browser.setSetting(path: "engines.rules", value: try PageCommands.json(rules))
            }
        }
    }

    func askPermission(for t: Tab, text: String) async -> (allow: Bool, remember: Bool) {
        if t !== active { activate(t) }
        let i = await permissionBar.ask(text, buttons: ["Allow once", "Allow", "Block"], owner: self)
        return (i == 0 || i == 1, i != 0)
    }

    func layoutStrips() { root.needsLayout = true }

    // MARK: Commands

    func focusURLField() {
        if paletteMode { openAddressPalette(prefill: active?.url?.absoluteString, newTab: active == nil); return }
        if focusMode { navForcedVisible = true; root.needsLayout = true; root.layoutSubtreeIfNeeded() }
        navBar.focusField(prefill: nil)
    }

    func openPalette() {
        if paletteMode { openAddressPalette(prefill: ">", newTab: false) }
        else {
            if focusMode { navForcedVisible = true; root.needsLayout = true; root.layoutSubtreeIfNeeded() }
            navBar.focusField(prefill: ">")
        }
    }

    func openAddressPalette(prefill: String?, newTab: Bool) {
        // An empty tab has its own field: the keyboard goes there rather than to a panel over it.
        if dockedField, active?.webView == nil { blank.focusField(prefill: prefill); return }
        palette.show(prefill: prefill, newTab: newTab)
    }
    var dockedField: Bool { paletteMode && browser.theme.window.newTab == .field }
    func urlFieldEnded() {
        if navForcedVisible { navForcedVisible = false; root.needsLayout = true }
    }

    /// Navigate from the URL field / palette.
    func go(_ url: URL, disposition: NavBar.Disposition) {
        switch disposition {
        case .current:
            if let a = active { a.navigate(url); attachActive(); focusContent() } else { openTab(url, activate: true) }
        case .newTab:
            openTab(url, activate: true)
            focusContent()
        case .childTab:
            if let a = active, a.url != nil { openChild(of: a, url: url, configuration: nil, activate: true) } else { go(url, disposition: .current) }
        case .newWindow:
            browser.newWindow(open: url)
        }
    }

    func openInternal(_ url: URL) {
        if let n = tree.allTabs.first(where: { $0.url?.scheme == InternalPages.scheme && $0.url?.host() == url.host() }) {
            let t = tab(n)
            activate(t)
            if t.url != url { t.navigate(url) }
        } else if let a = active, a.url == nil, !a.isLoaded {
            a.navigate(url)
            activate(a)
        } else {
            openTab(url, activate: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func zoom(by delta: Double?) {
        guard let t = active, let wv = t.webView, let url = t.url else { return }
        let z = delta.map { min(3, max(0.3, (wv.pageZoom + $0) * 100).rounded() / 100) } ?? browser.settings.content.zoom
        wv.pageZoom = z
        if delta == nil { wv.magnification = 1 }
        browser.updateSite(url) { $0.zoom = abs(z - browser.settings.content.zoom) < 0.001 ? nil : z }
        toast("\(Int((z * 100).rounded()))%", color: style.secondary)
    }

    /// Change the current site's overrides and reload so the page picks them up.
    func changeSite(reload: Bool = true, _ change: (SitePolicy, inout SiteOverrides) -> Void) {
        guard let t = active, let url = t.url, url.scheme == "http" || url.scheme == "https" else {
            toast("no site settings for this page", color: style.muted)
            return
        }
        let p = browser.policy(for: url)
        browser.updateSite(url) { change(p, &$0) }
        let n = browser.policy(for: url)
        var bits: [String] = []
        if n.javascript != p.javascript { bits.append("JavaScript \(n.javascript ? "on" : "off")") }
        if n.square != p.square { bits.append("square \(n.square ? "on" : "off")") }
        if n.dark != p.dark { bits.append("dark \(n.dark.rawValue)") }
        if n.blocker != p.blocker { bits.append("blocker \(n.blocker ? "on" : "off")") }
        if n.blockRemoteFonts != p.blockRemoteFonts { bits.append("remote fonts \(n.blockRemoteFonts ? "blocked" : "allowed")") }
        if !bits.isEmpty { toast(bits.joined(separator: " · "), color: style.secondary) }
        if reload { t.reload(fromOrigin: false) } else { t.invalidatePolicy() }
        navBar.update()
    }

    func showSitePanel() {
        if let p = sitePanel, p.isVisible { p.close(); return }
        guard let t = active, ["http", "https"].contains(t.url?.scheme) else {
            toast("no site settings for this page", color: style.muted)
            return
        }
        let panel = SitePanel(owner: self, tab: t)
        sitePanel = panel
        panel.show(below: siteButtonRectOnScreen)
    }

    func showFind() {
        guard active?.webView != nil else { return }
        if focusMode { navForcedVisible = false }
        findBar.isHidden = false
        root.needsLayout = true
        findBar.focus()
    }

    func hideFind() {
        findBar.isHidden = true
        root.needsLayout = true
        focusContent()
    }

    func findNext(backwards: Bool) {
        if findBar.isHidden { showFind() } else { findBar.find(backwards: backwards) }
    }

    func bookmarkActive() {
        guard let t = active, let url = t.url else { return }
        var store = browser.bookmarks
        if store.flattened().contains(where: { $0.url == url.absoluteString }) {
            toast("already bookmarked", color: style.muted)
            return
        }
        store.add(Bookmark(title: t.displayTitle, url: url.absoluteString), toFolderNamed: "Bookmarks")
        browser.setBookmarks(store)
        toast("bookmarked", color: style.ok)
    }

    func toggleFavorite(_ node: TabNode) {
        guard browser.settings.tabs.favorites, let url = node.url?.absoluteString else { return }
        var store = browser.bookmarks
        let existing = store.flattened().first { $0.url == url }
        let favorite = !(existing?.favorite ?? false)
        if existing == nil {
            store.add(Bookmark(title: node.title, url: url, favorite: true), toFolderNamed: "Bookmarks")
        } else {
            store.setFavorite(favorite, url: url)
        }
        browser.setBookmarks(store)
    }

    func copyCleanURL() {
        guard let url = active?.url else { return }
        let clean = CleanURL.clean(url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clean.absoluteString, forType: .string)
        toast("copied \(Omnibox.display(clean))", color: style.secondary)
    }

    func handoffActive(engine: Engine?) {
        guard let url = active?.url else { return }
        let last = UserDefaults.standard.string(forKey: "angl.lastEngine").flatMap(Engine.engine(id:))
        guard let e = engine ?? (last.flatMap { Handoff.appURL(for: $0) != nil ? $0 : nil }) ?? Handoff.installed.first else {
            toast("no other browser installed", color: style.muted)
            return
        }
        UserDefaults.standard.set(e.id, forKey: "angl.lastEngine")
        Task { @MainActor in
            if await Handoff.open(url, in: e) { toast("opened in \(e.name)", color: style.secondary) }
        }
    }

    func focusSidebar() {
        if sidebarHidden { toggleSidebar() }
        sidebar.focusTree()
    }

    func toggleSidebar() {
        sidebarHidden.toggle()
        peeking = false
        sidebar.updatePaletteHeader()
        root.needsLayout = true
        browser.markSessionDirty()
    }

    func toggleFocusMode() {
        focusMode.toggle()
        navForcedVisible = false
        root.needsLayout = true
    }

    func refreshContentPolicies() {
        for (_, t) in tabs where t.isLoaded {
            t.invalidatePolicy()
            t.webView?.isInspectable = browser.settings.developer.inspector
        }
        navBar.update()
        sidebar.updatePaletteHeader()
    }

    func toast(_ text: String, color: NSColor) {
        status.flash(text, color: color)
    }

    // MARK: Sidebar peek / resize

    private func schedulePeek(_ show: Bool) {
        guard sidebarHidden, !focusMode else { return }
        peekTimer?.invalidate()
        let delay = (show ? browser.theme.sidebar.peekDelayMs : browser.theme.sidebar.hideDelayMs) / 1000
        peekTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.peeking != show else { return }
                self.peeking = show
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.root.layoutPanes(animated: true)
                }
            }
        }
    }

    private func resizeSidebar(by dx: CGFloat) {
        sidebarWidth = min(360, max(140, sidebarWidth + dx))
        root.needsLayout = true
        browser.markSessionDirty()
    }


    // MARK: Layout

    private func layoutContentPanes() {
        guard browser.settings.tabs.splitView, let s = splits[workspaceID],
              let first = tree.node(s.first).flatMap({ tabs[$0.id]?.webView }),
              let second = tree.node(s.second).flatMap({ tabs[$0.id]?.webView }) else {
            active?.webView?.frame = content.bounds
            splitDivider.isHidden = true
            paneMarker.isHidden = true
            return
        }
        let dividerWidth: CGFloat = 5
        let leftWidth = ((content.bounds.width - dividerWidth) * s.ratio).rounded()
        first.frame = NSRect(x: 0, y: 0, width: leftWidth, height: content.bounds.height)
        second.frame = NSRect(x: leftWidth + dividerWidth, y: 0,
                              width: content.bounds.width - leftWidth - dividerWidth, height: content.bounds.height)
        first.isHidden = false
        second.isHidden = false
        splitDivider.frame = NSRect(x: leftWidth, y: 0, width: dividerWidth, height: content.bounds.height)
        splitDivider.fill = style.base; splitDivider.borderColor = style.border
        splitDivider.isHidden = false
        content.addSubview(splitDivider, positioned: .above, relativeTo: nil)
        // A 1 pt accent outline around the focused pane.
        let focused = s.focused == s.first ? first.frame : second.frame
        paneMarker.fill = nil
        paneMarker.borderColor = style.accent
        paneMarker.edges = .all
        paneMarker.frame = focused
        paneMarker.isHidden = false
        content.addSubview(paneMarker, positioned: .above, relativeTo: nil)
    }

    func layoutPanes(in bounds: NSRect, animated: Bool) {
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        let navH: CGFloat = paletteMode ? 0 : ((focusMode && !navForcedVisible) ? 0 : style.navBar)
        let showSidebar = !focusMode && (!sidebarHidden || peeking)
        let overlay = sidebarHidden && peeking
        func set(_ v: NSView, _ r: NSRect) { animated ? (v.animator().frame = r) : (v.frame = r) }

        navBar.isHidden = paletteMode || navH == 0
        navBar.leadingInset = fullScreen || navH == 0 ? 8 : 78
        set(navBar, NSRect(x: 0, y: 0, width: bounds.width, height: navH))

        let sideW = sidebarWidth
        let sideX: CGFloat = showSidebar ? 0 : -sideW
        let sidebarY: CGFloat = paletteMode ? 0 : navH
        set(sidebar, NSRect(x: sideX, y: sidebarY, width: sideW, height: bounds.height - sidebarY))
        sidebar.isHidden = focusMode
        sidebar.paletteHeaderVisible = paletteMode
        resizeHandle.isHidden = !showSidebar || overlay
        resizeHandle.frame = NSRect(x: sideW - 3, y: sidebarY, width: 6, height: bounds.height - sidebarY)
        let catchW = CGFloat(browser.theme.sidebar.peekWidth)
        edge.isHidden = !(sidebarHidden && !focusMode) || catchW <= 0
        edge.frame = NSRect(x: 0, y: sidebarY, width: catchW, height: bounds.height - sidebarY)
        root.addSubview(sidebar, positioned: .above, relativeTo: content)

        let placement = browser.theme.window.outline
        let inset: CGFloat = placement == .content && !fullScreen && !focusMode ? 6 : 0
        let contentX: CGFloat = (showSidebar && !overlay ? sideW : 0) + inset
        var y = navH + inset
        for bar in [permissionBar, findBar!] as [NSView] where !bar.isHidden {
            bar.frame = NSRect(x: contentX, y: y, width: max(0, bounds.width - contentX - inset), height: 28)
            y += 28
        }
        set(content, NSRect(x: contentX, y: y, width: max(0, bounds.width - contentX - inset), height: max(0, bounds.height - y - inset)))
        blank.frame = content.bounds
        layoutContentPanes()
        status.reposition(in: content.bounds)
        updateProgressLine()
        content.layer?.cornerRadius = inset > 0 ? 4 : 0
        content.layer?.masksToBounds = inset > 0
        contentFrame.frame = NSRect(x: contentX, y: navH + inset, width: max(0, bounds.width - contentX - inset), height: max(0, bounds.height - navH - 2 * inset))
        configureOutline(fullScreen: fullScreen)

        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window?.standardWindowButton(kind), let sv = b.superview else { continue }
            // Shown with whatever hosts them: the nav bar, or the sidebar header in palette mode.
            b.isHidden = !fullScreen && (paletteMode ? !showSidebar : navH == 0)
            if !fullScreen {
                let yy = sv.bounds.height - style.navBar / 2 - b.frame.height / 2
                b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: max(0, yy)))
            }
        }
        configureOutline(fullScreen: fullScreen)
    }

    /// The palette-mode load indicator: 2 px along the top of the page.
    func updateProgressLine() {
        progressLine.isHidden = !paletteMode || active?.isLoading != true
        progressLine.frame = NSRect(x: 0, y: 0, width: content.bounds.width * max(0.05, active?.progress ?? 0), height: 2)
    }

    private func applyStyle() {
        let s = style
        window?.backgroundColor = s.base
        content.fill = s.base
        navBar.applyStyle()
        sidebar.applyStyle()
        palette.applyStyle()
        findBar.applyStyle()
        permissionBar.applyStyle(s)
        status.applyStyle(s)
        blank.applyStyle(s)
        if !paletteMode { palette.closePalette() }
        progressLine.fill = s.accent
        for (_, t) in tabs { t.webView?.underPageBackgroundColor = s.base }
        root.needsLayout = true
    }

    private func configureOutline(fullScreen: Bool) {
        let theme = browser.theme.window
        let color: NSColor
        switch theme.outlineColor {
        case .accent: color = style.accent
        case .border: color = style.border
        case .container: color = active.map { style.workspaceColor(container(for: $0.node).color) } ?? style.workspaceColor(workspace.color)
        case .custom: color = Style.color(theme.outlineCustomColor)
        }
        let activeWindow = window?.isKeyWindow == true || palette.isKeyWindow
        let opacity = activeWindow ? theme.outlineOpacity : theme.outlineInactiveOpacity
        let scale = window?.backingScaleFactor ?? 1
        let width = max(1 / scale, CGFloat(theme.outlineWidth))
        contentFrame.isHidden = theme.outline != .content || fullScreen || focusMode
        contentFrame.color = color.withAlphaComponent(CGFloat(opacity))
        contentFrame.lineWidth = width
        sidebar.updateOutline(color: color.withAlphaComponent(CGFloat(opacity)), width: width, visible: theme.outline == .seam && !fullScreen && !focusMode)
    }
}

final class ContentFrameView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 1 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), xRadius: 4, yRadius: 4)
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}


extension BrowserWindowController {

    // MARK: Session

    func saved() -> SavedWindow {
        for (_, t) in tabs where t.isLoaded { t.captureState() }
        let order = browser.workspaces.workspaces.map(\.id)
        let saved = order.compactMap { id -> SavedTree? in
            guard let tr = trees[id], !tr.isEmpty else { return nil }
            return SavedTree(workspaceID: id, tree: tr, activeTab: activeByWorkspace[id], split: storedSplits[id])
        }
        return SavedWindow(frame: window.map { NSStringFromRect($0.frame) }, activeWorkspace: workspaceID, trees: saved,
                           sidebarHidden: sidebarHidden, sidebarWidth: Double(sidebarWidth))
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) { browser.markSessionDirty() }
    func windowDidMove(_ notification: Notification) { browser.markSessionDirty() }
    func windowDidEnterFullScreen(_ notification: Notification) { root.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) { root.needsLayout = true }

    func windowWillMiniaturize(_ notification: Notification) {
        if let active { Passwords.shared.pageHidden(in: active) }
    }

    func windowWillClose(_ notification: Notification) {
        sitePanel?.close()
        navBar.closeSuggestions()
        for (_, t) in tabs { t.unload() }
        tabs.removeAll()
        notes.forEach(NotificationCenter.default.removeObserver)
        browser.unregister(self)
    }
}

/// The window: Esc falls through to angl after web content and fields had their chance.
final class AnglWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        guard let c = windowController as? BrowserWindowController else { return }
        if c.findVisible { c.hideFind() } else if c.active?.isLoading == true { c.active?.webView?.stopLoading() }
        else if c.focusMode { c.toggleFocusMode() }
    }
}

/// Root content view: flipped, lays the panes out by hand.
final class RootView: NSView {
    weak var controller: BrowserWindowController?
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        controller?.layoutPanes(in: bounds, animated: false)
    }

    /// Reading order: chrome (nav bar, sidebar, bars) before page content, whatever the z-order.
    override func accessibilityChildren() -> [Any]? {
        guard let all = super.accessibilityChildren(), let page = controller?.content else { return super.accessibilityChildren() }
        let isPage = { (e: Any) in (e as? NSView)?.isDescendant(of: page) ?? false }
        return all.filter { !isPage($0) } + all.filter(isPage)
    }

    func layoutPanes(animated: Bool) {
        controller?.layoutPanes(in: bounds, animated: animated)
    }
}

/// Invisible strip at the window's left edge that peeks the hidden sidebar (`theme.sidebar.peekWidth`).
/// Hover-only: clicks fall through to the page underneath.
final class EdgeTrigger: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// Drag handle on the sidebar's right edge.
final class ResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var last: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - last)
        last = x
    }
}

/// Draggable divider between the two split panes: a centred hairline over the window background.
final class SplitDivider: FlatView {
    var onDrag: ((CGFloat) -> Void)?
    private var last: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        if let fill { fill.setFill(); bounds.fill() }
        borderColor?.setFill()
        NSRect(x: (bounds.width / 2).rounded(.down), y: 0, width: 1, height: bounds.height).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - last)
        last = x
    }
}

/// Outline drawn over the focused split pane; clicks pass through to the page.
final class PaneOutline: FlatView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
