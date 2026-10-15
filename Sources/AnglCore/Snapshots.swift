import Foundation

/// A complete restorable browser state.
public struct Snapshot: Codable, Sendable {
    public var date: Date
    public var auto: Bool
    public var workspaces: WorkspaceConfig
    public var session: SessionState

    public init(date: Date = Date(), auto: Bool = false, workspaces: WorkspaceConfig, session: SessionState) {
        self.date = date
        self.auto = auto
        self.workspaces = workspaces
        self.session = session
    }
}

/// Summary of a saved snapshot.
public struct SnapshotInfo: Codable, Sendable {
    public var id: String
    public var date: Date
    public var auto: Bool
    public var windows: Int
    public var workspaces: Int
    public var tabs: Int
}

/// Reads, writes, lists, and prunes snapshots in a directory.
public struct SnapshotStore {
    private let dir: URL
    public init(dir: URL) { self.dir = dir }

    private var files: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
    }

    /// Lists readable snapshots, newest first.
    public func list() -> [SnapshotInfo] {
        files.compactMap { url in
            guard let snapshot = try? JSONFile.read(Snapshot.self, from: url) else { return nil }
            return SnapshotInfo(id: url.deletingPathExtension().lastPathComponent, date: snapshot.date,
                                auto: snapshot.auto, windows: snapshot.session.windows.count,
                                workspaces: snapshot.workspaces.workspaces.count, tabs: snapshot.session.tabCount)
        }.sorted { $0.date > $1.date }
    }

    /// Saves a snapshot using a UTC timestamp filename.
    public func save(_ snapshot: Snapshot) throws -> SnapshotInfo {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let id = formatter.string(from: snapshot.date) + (snapshot.auto ? "-auto" : "")
        try JSONFile.write(snapshot, to: dir.appendingPathComponent(id + ".json"))
        return SnapshotInfo(id: id, date: snapshot.date, auto: snapshot.auto,
                            windows: snapshot.session.windows.count,
                            workspaces: snapshot.workspaces.workspaces.count, tabs: snapshot.session.tabCount)
    }

    /// Loads a snapshot by file stem.
    public func load(id: String) throws -> Snapshot {
        guard let snapshot = try JSONFile.read(Snapshot.self, from: dir.appendingPathComponent(id + ".json")) else {
            throw NSError(domain: "Snapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Snapshot not found: \(id)"])
        }
        return snapshot
    }

    /// Deletes a snapshot by file stem.
    public func delete(id: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".json")) }

    /// Keeps recent automatic snapshots and the newest automatic snapshot for each of 30 days.
    public func prune(keepAuto: Int) {
        let automatic = list().filter(\.auto)
        let retained = Set(automatic.prefix(max(0, keepAuto)).map(\.id))
        let calendar = Calendar(identifier: .gregorian)
        for item in automatic where !retained.contains(item.id) {
            let age = calendar.dateComponents([.day], from: item.date, to: Date()).day ?? Int.max
            let newestToday = automatic.first { calendar.isDate($0.date, inSameDayAs: item.date) }?.id == item.id
            if age >= 0 && age < 30 && newestToday { continue }
            delete(id: item.id)
        }
    }
}
