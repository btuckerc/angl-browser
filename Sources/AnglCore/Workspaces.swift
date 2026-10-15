import Foundation

/// A container is an isolated cookie/storage jar (one WKWebsiteDataStore), optionally behind a proxy.
public struct Container: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Hex colour shown as the square in the URL field.
    public var color: String
    public var proxy: Proxy?
    /// Wipe cookies and storage when angl quits.
    public var clearOnQuit: Bool

    public init(id: UUID = UUID(), name: String, color: String, proxy: Proxy? = nil, clearOnQuit: Bool = false) {
        self.id = id; self.name = name; self.color = color; self.proxy = proxy; self.clearOnQuit = clearOnQuit
    }

    /// The container every profile starts with; its identifier is fixed so it survives edits.
    public static let defaultID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
}

public struct Proxy: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case http, socks5 }
    public var kind: Kind
    public var host: String
    public var port: Int

    public init(kind: Kind, host: String, port: Int) {
        self.kind = kind; self.host = host; self.port = port
    }

    public var label: String { "\(kind.rawValue)://\(host):\(port)" }
}

/// A workspace is a coloured set of tab trees (one per window) bound to a container.
public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var color: String
    public var containerID: UUID
    /// Navigations matching any rule move into this workspace (and its container).
    public var rules: [URLRule]

    public init(id: UUID = UUID(), name: String, color: String, containerID: UUID, rules: [URLRule] = []) {
        self.id = id; self.name = name; self.color = color; self.containerID = containerID; self.rules = rules
    }
}

/// workspaces.json: the profile's containers and workspaces, in sidebar order.
public struct WorkspaceConfig: Codable, Equatable, Sendable {
    public var containers: [Container]
    public var workspaces: [Workspace]

    public init(containers: [Container], workspaces: [Workspace]) {
        self.containers = containers; self.workspaces = workspaces
    }

    public static func initial(theme: Theme = Theme()) -> WorkspaceConfig {
        let c = Container(id: Container.defaultID, name: "Default", color: theme.color.workspaces.first ?? "#55c3e8")
        let w = Workspace(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                          name: "Main", color: c.color, containerID: c.id)
        return WorkspaceConfig(containers: [c], workspaces: [w])
    }

    public func container(_ id: UUID) -> Container? { containers.first { $0.id == id } }
    public func workspace(_ id: UUID) -> Workspace? { workspaces.first { $0.id == id } }

    /// First workspace (other than `current`) with a rule matching `url`.
    public func workspace(claiming url: URL, current: UUID?) -> Workspace? {
        if let current, let w = workspace(current), w.rules.contains(where: { $0.matches(url) }) { return nil }
        return workspaces.first { $0.id != current && $0.rules.contains(where: { $0.matches(url) }) }
    }

    /// Invariants: at least one container and workspace; every workspace points at a real container.
    public mutating func repair(theme: Theme = Theme()) {
        if containers.isEmpty { containers = WorkspaceConfig.initial(theme: theme).containers }
        if workspaces.isEmpty { workspaces = WorkspaceConfig.initial(theme: theme).workspaces }
        let ids = Set(containers.map(\.id))
        for i in workspaces.indices where !ids.contains(workspaces[i].containerID) {
            workspaces[i].containerID = containers[0].id
        }
    }
}
