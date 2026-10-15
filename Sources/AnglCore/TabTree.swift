import Foundation

/// A node in a workspace's tab tree: a tab or a named folder. Reference type so the sidebar's
/// outline view can use nodes as stable items. Main-thread only.
public final class TabNode: Identifiable {
    public enum Kind: String, Codable, Sendable { case tab, folder }

    public let id: UUID
    public let kind: Kind
    public var title: String
    public var url: URL?
    /// Tabs only: overrides the workspace's container (set when a URL rule or "open in container" moved it).
    public var containerID: UUID?
    public var collapsed: Bool
    /// WKWebView.interactionState (back/forward list, scroll) captured when a tab unloads.
    public var interactionState: Data?
    public var lastActive: Date
    public internal(set) weak var parent: TabNode?
    public internal(set) var children: [TabNode] = []

    public init(id: UUID = UUID(), kind: Kind, title: String, url: URL? = nil, containerID: UUID? = nil,
                collapsed: Bool = false, interactionState: Data? = nil, lastActive: Date = Date()) {
        self.id = id; self.kind = kind; self.title = title; self.url = url; self.containerID = containerID
        self.collapsed = collapsed; self.interactionState = interactionState; self.lastActive = lastActive
    }

    public static func tab(_ url: URL?, title: String = "", containerID: UUID? = nil) -> TabNode {
        TabNode(kind: .tab, title: title, url: url, containerID: containerID)
    }

    public var isFolder: Bool { kind == .folder }

    public var depth: Int {
        var d = 0, p = parent
        while let n = p, n.parent != nil { d += 1; p = n.parent }
        return d
    }

    /// Self and every descendant, depth-first.
    public var subtree: [TabNode] { [self] + children.flatMap(\.subtree) }

    public func isAncestor(of node: TabNode) -> Bool {
        var p = node.parent
        while let n = p { if n === self { return true }; p = n.parent }
        return false
    }

    func detach() {
        parent?.children.removeAll { $0 === self }
        parent = nil
    }
}

/// One workspace's tabs in one window: a pinned row plus a tree.
public final class TabTree {
    public let root = TabNode(kind: .folder, title: "")
    public private(set) var pinned: [TabNode] = []

    public init() {}

    public var isEmpty: Bool { root.children.isEmpty && pinned.isEmpty }

    /// Every tab (not folder), pinned first, then tree order.
    public var allTabs: [TabNode] { pinned + root.children.flatMap(\.subtree).filter { !$0.isFolder } }

    public func node(_ id: UUID) -> TabNode? { pinned.first { $0.id == id } ?? root.subtree.first { $0.id == id } }

    public func isPinned(_ node: TabNode) -> Bool { pinned.contains { $0 === node } }

    /// Visible rows in tree order (collapsed subtrees hidden).
    public var visibleNodes: [TabNode] {
        func walk(_ n: TabNode) -> [TabNode] { [n] + (n.collapsed ? [] : n.children.flatMap(walk)) }
        return root.children.flatMap(walk)
    }

    /// Insert `node` under `parent` (nil = top level) at `index` (nil = end).
    public func insert(_ node: TabNode, under parent: TabNode? = nil, at index: Int? = nil) {
        let p = parent ?? root
        precondition(node !== p && !node.isAncestor(of: p), "cycle")
        unlink(node)
        let i = min(max(index ?? p.children.count, 0), p.children.count)
        p.children.insert(node, at: i)
        node.parent = p
    }

    /// Insert right after `sibling`, at the same level.
    public func insert(_ node: TabNode, after sibling: TabNode) {
        guard node !== sibling else { return }
        unlink(node)
        guard let p = sibling.parent, let i = p.children.firstIndex(where: { $0 === sibling }) else {
            insert(node); return
        }
        insert(node, under: p === root ? nil : p, at: i + 1)
    }

    public func pin(_ node: TabNode, at index: Int? = nil) {
        guard !node.isFolder else { return }
        // Children of a pinned tab stay in the tree where the tab was.
        promoteChildren(of: node)
        unlink(node)
        pinned.insert(node, at: min(index ?? pinned.count, pinned.count))
    }

    public func unpin(_ node: TabNode) {
        guard isPinned(node) else { return }
        pinned.removeAll { $0 === node }
        insert(node, under: nil, at: 0)
    }

    /// Remove a node, lifting its children into its place (Sidebery behaviour). Returns removed tabs.
    @discardableResult
    public func remove(_ node: TabNode) -> [TabNode] {
        if isPinned(node) { pinned.removeAll { $0 === node }; return [node] }
        promoteChildren(of: node)
        node.detach()
        return node.isFolder ? [] : [node]
    }

    /// Remove a node and everything under it. Returns removed tabs.
    @discardableResult
    public func removeSubtree(_ node: TabNode) -> [TabNode] {
        if isPinned(node) { return remove(node) }
        let tabs = node.subtree.filter { !$0.isFolder }
        node.detach()
        return tabs
    }

    /// Wrap `nodes` in a new folder placed where the first of them was. Nodes keep their subtrees;
    /// a node whose ancestor is also selected moves with that ancestor.
    @discardableResult
    public func group(_ nodes: [TabNode], name: String) -> TabNode? {
        let tops = nodes.filter { n in !isPinned(n) && !nodes.contains { $0 !== n && $0.isAncestor(of: n) } }
        guard let first = tops.first, let p = first.parent,
              let i = p.children.firstIndex(where: { $0 === first }) else { return nil }
        let folder = TabNode(kind: .folder, title: name)
        insert(folder, under: p === root ? nil : p, at: i)
        for n in tops { insert(n, under: folder) }
        return folder
    }

    /// Replace a folder with its children.
    public func ungroup(_ folder: TabNode) {
        guard folder.isFolder, folder !== root else { return }
        remove(folder)
    }

    /// Next tab to show after `node` closes: the previous sibling's last tab, else (when children are
    /// promoted) its first child, else the next sibling, else the nearest ancestor tab, else any tab.
    public func successor(of node: TabNode, closingSubtree: Bool = false) -> TabNode? {
        if isPinned(node) {
            let others = pinned.filter { $0 !== node }
            return others.last ?? root.children.flatMap(\.subtree).first { !$0.isFolder }
        }
        let gone = Set(closingSubtree ? node.subtree.map(\.id) : [node.id])
        if let p = node.parent, let i = p.children.firstIndex(where: { $0 === node }) {
            for s in p.children[..<i].reversed() { if let t = s.subtree.last(where: { !$0.isFolder }) { return t } }
            if !closingSubtree, let t = node.children.lazy.compactMap({ $0.subtree.first { !$0.isFolder } }).first {
                return t
            }
            for s in p.children[(i + 1)...] { if let t = s.subtree.first(where: { !$0.isFolder }) { return t } }
            var a: TabNode? = p
            while let n = a, n !== root { if !n.isFolder { return n }; a = n.parent }
        }
        return allTabs.first { !gone.contains($0.id) }
    }

    private func promoteChildren(of node: TabNode) {
        guard let p = node.parent, let i = p.children.firstIndex(where: { $0 === node }) else { return }
        let kids = node.children
        for (k, c) in kids.enumerated() {
            c.detach()
            p.children.insert(c, at: i + 1 + k)
            c.parent = p
        }
    }

    private func unlink(_ node: TabNode) {
        pinned.removeAll { $0 === node }
        node.detach()
    }
}

// MARK: - Persistence

public struct SavedNode: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: TabNode.Kind
    public var title: String
    public var url: String?
    public var containerID: UUID?
    public var collapsed: Bool?
    public var state: Data?
    public var lastActive: Date?
    public var children: [SavedNode]?

    public init(_ n: TabNode) {
        id = n.id; kind = n.kind; title = n.title; url = n.url?.absoluteString; containerID = n.containerID
        collapsed = n.collapsed ? true : nil; state = n.interactionState; lastActive = n.lastActive
        children = n.children.isEmpty ? nil : n.children.map(SavedNode.init)
    }

    public func makeNode(into tree: TabTree, under parent: TabNode?) {
        let n = TabNode(id: id, kind: kind, title: title, url: url.flatMap(URL.init(string:)),
                        containerID: containerID, collapsed: collapsed ?? false, interactionState: state,
                        lastActive: lastActive ?? Date())
        tree.insert(n, under: parent)
        for c in children ?? [] { c.makeNode(into: tree, under: n) }
    }
}

public struct SavedSplit: Codable, Equatable, Sendable {
    public var firstTab: UUID
    public var secondTab: UUID
    public var focusedTab: UUID
    public var ratio: Double

    public init(firstTab: UUID, secondTab: UUID, focusedTab: UUID, ratio: Double) {
        self.firstTab = firstTab
        self.secondTab = secondTab
        self.focusedTab = focusedTab
        self.ratio = min(0.8, max(0.2, ratio))
    }
}

public struct SavedTree: Codable, Equatable, Sendable {
    public var workspaceID: UUID
    public var activeTab: UUID?
    public var pinned: [SavedNode]
    public var nodes: [SavedNode]
    public var split: SavedSplit?

    public init(workspaceID: UUID, tree: TabTree, activeTab: UUID?, split: SavedSplit? = nil) {
        self.workspaceID = workspaceID
        self.activeTab = activeTab
        pinned = tree.pinned.map(SavedNode.init)
        nodes = tree.root.children.map(SavedNode.init)
        self.split = split
    }

    public func makeTree() -> TabTree {
        let t = TabTree()
        for p in pinned {
            let n = TabNode(id: p.id, kind: .tab, title: p.title, url: p.url.flatMap(URL.init(string:)),
                            containerID: p.containerID, interactionState: p.state, lastActive: p.lastActive ?? Date())
            t.pin(n)
        }
        for n in nodes { n.makeNode(into: t, under: nil) }
        return t
    }

    public var tabCount: Int {
        func count(_ n: SavedNode) -> Int { (n.kind == .tab ? 1 : 0) + (n.children ?? []).map(count).reduce(0, +) }
        return pinned.count + nodes.map(count).reduce(0, +)
    }
}

public struct SavedWindow: Codable, Equatable, Sendable {
    public var frame: String?
    public var activeWorkspace: UUID
    public var trees: [SavedTree]
    public var sidebarHidden: Bool?
    public var sidebarWidth: Double?

    public init(frame: String?, activeWorkspace: UUID, trees: [SavedTree], sidebarHidden: Bool?, sidebarWidth: Double?) {
        self.frame = frame; self.activeWorkspace = activeWorkspace; self.trees = trees
        self.sidebarHidden = sidebarHidden; self.sidebarWidth = sidebarWidth
    }
}

/// session.json and the body of every snapshot.
public struct SessionState: Codable, Equatable, Sendable {
    public var windows: [SavedWindow]
    public init(windows: [SavedWindow]) { self.windows = windows }

    public var tabCount: Int { windows.flatMap(\.trees).map(\.tabCount).reduce(0, +) }
}
