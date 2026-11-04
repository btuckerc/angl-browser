import Foundation

/// When each login was last filled on this Mac: login IDs → seconds since 1970, nothing else
/// (no hosts, no searches). Ranks a page's logins (`LoginIndex.Ranking.lastUsed`).
public struct LoginUsage: Sendable {
    public private(set) var lastUsed: [String: Double]
    private let file: URL

    /// Reads `file`; a missing or unreadable file starts empty.
    public init(file: URL) {
        self.file = file
        lastUsed = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: file))) ?? [:]
    }

    public mutating func record(_ id: String, at date: Date = Date()) {
        lastUsed[id] = date.timeIntervalSince1970
        save()
    }

    /// Drops logins the vault no longer has.
    public mutating func prune(keeping ids: Set<String>) {
        let kept = lastUsed.filter { ids.contains($0.key) }
        guard kept.count != lastUsed.count else { return }
        lastUsed = kept
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(lastUsed) else { return }
        let fm = FileManager.default, dir = file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? data.write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
