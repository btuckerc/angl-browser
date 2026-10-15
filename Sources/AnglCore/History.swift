import Foundation
import SQLite3

/// A stored page visit summary.
public struct HistoryItem: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var lastVisit: Date
    public var visits: Int

    public init(url: String, title: String, lastVisit: Date, visits: Int) {
        self.url = url
        self.title = title
        self.lastVisit = lastVisit
        self.visits = visits
    }
}

public enum RecoveryReason: String, Codable, Sendable { case closed, archived }

/// A tab removed from a tree but retained for recovery.
public struct RecoveryRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var saved: SavedNode
    public var workspaceID: UUID
    public var parentID: UUID?
    public var index: Int
    public var reason: RecoveryReason
    public var createdAt: Date

    public init(id: UUID = UUID(), saved: SavedNode, workspaceID: UUID, parentID: UUID?,
                index: Int, reason: RecoveryReason, createdAt: Date = Date()) {
        self.id = id
        self.saved = saved
        self.workspaceID = workspaceID
        self.parentID = parentID
        self.index = index
        self.reason = reason
        self.createdAt = createdAt
    }
}

/// SQLite-backed browsing history, serialized on one queue.
public final class HistoryStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "angl.history.sqlite")
    private var db: OpaquePointer?

    /// Opens or creates a history database.
    public init(url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let connection { sqlite3_close(connection) }
            throw NSError(domain: "History", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        db = connection
        let sql = "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS visits (url TEXT PRIMARY KEY, title TEXT, last_visit REAL, visit_count INTEGER, typed_count INTEGER); CREATE INDEX IF NOT EXISTS visits_last_visit ON visits(last_visit); CREATE TABLE IF NOT EXISTS recovery (id TEXT PRIMARY KEY, reason TEXT NOT NULL, created_at REAL NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, payload BLOB NOT NULL)"
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(connection))
            sqlite3_close(connection)
            db = nil
            throw NSError(domain: "History", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    private func bind(_ statement: OpaquePointer?, values: [Any]) {
        for (index, value) in values.enumerated() {
            let column = Int32(index + 1)
            if let value = value as? String {
                sqlite3_bind_text(statement, column, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else if let value = value as? Double {
                sqlite3_bind_double(statement, column, value)
            } else if let value = value as? Int {
                sqlite3_bind_int64(statement, column, Int64(value))
            }
        }
    }

    /// Runs one statement; call on `queue`.
    private func run(_ sql: String, _ values: [Any]) {
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, values: values)
        sqlite3_step(statement)
    }

    private func execute(_ sql: String, values: [Any] = []) { queue.sync { run(sql, values) } }

    /// Visit and title writes: queued in order on the serial queue so navigation never waits on disk.
    private func enqueue(_ sql: String, values: [Any]) {
        nonisolated(unsafe) let values = values
        queue.async { [self] in run(sql, values) }
    }

    /// Waits for queued writes (normal quit).
    public func flush() { queue.sync {} }

    /// Records an HTTP(S) visit asynchronously; unsupported schemes are ignored.
    public func record(url: URL, title: String?, typed: Bool) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        enqueue("INSERT INTO visits VALUES (?, ?, ?, 1, ?) ON CONFLICT(url) DO UPDATE SET title=excluded.title, last_visit=excluded.last_visit, visit_count=visit_count+1, typed_count=typed_count+excluded.typed_count",
                values: [url.absoluteString, title ?? "", Date().timeIntervalSince1970, typed ? 1 : 0])
    }

    /// Updates a visit's title.
    public func updateTitle(url: URL, title: String?) {
        enqueue("UPDATE visits SET title=? WHERE url=?", values: [title ?? "", url.absoluteString])
    }

    private func select(_ sql: String, values: [Any]) -> [HistoryItem] {
        queue.sync {
            guard let db else { return [] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            bind(statement, values: values)
            var items: [HistoryItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let url = String(cString: sqlite3_column_text(statement, 0))
                let title = String(cString: sqlite3_column_text(statement, 1))
                let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                let visits = Int(sqlite3_column_int(statement, 3))
                items.append(HistoryItem(url: url, title: title, lastVisit: date, visits: visits))
            }
            return items
        }
    }

    /// Searches every whitespace-separated term; ranked by frecency, or newest first when `recent`.
    public func query(_ text: String, limit: Int, offset: Int, recent: Bool = false) -> [HistoryItem] {
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map { "%\($0)%" }
        let clauses = terms.map { _ in "(url LIKE ? COLLATE NOCASE OR title LIKE ? COLLATE NOCASE)" }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let order = recent ? "last_visit DESC" : "(visit_count+2*typed_count)/(1+MAX(0,(strftime('%s','now')-last_visit)/86400.0)) DESC,last_visit DESC"
        let sql = "SELECT url,title,last_visit,visit_count FROM visits \(whereClause) ORDER BY \(order) LIMIT ? OFFSET ?"
        return select(sql, values: terms.flatMap { [$0, $0] } + [max(0, limit), max(0, offset)])
    }

    /// Suggests URL matches after ignoring scheme and www, then title matches.
    public func suggest(_ prefix: String, limit: Int) -> [HistoryItem] {
        let needle = prefix.lowercased()
        let items = select("SELECT url,title,last_visit,visit_count FROM visits WHERE url LIKE ? OR title LIKE ? ORDER BY (visit_count+2*typed_count) DESC",
                           values: ["%\(prefix)%", "%\(prefix)%"])
        return items.sorted {
            func matches(_ item: HistoryItem) -> Bool {
                var value = item.url.lowercased()
                if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
                if value.hasPrefix("www.") { value.removeFirst(4) }
                return value.hasPrefix(needle)
            }
            let a = matches($0), b = matches($1)
            return a == b ? ($0.visits > $1.visits) : a
        }.prefix(max(0, limit)).map { $0 }
    }

    /// Deletes one URL.
    public func delete(url: URL) { execute("DELETE FROM visits WHERE url=?", values: [url.absoluteString]) }

    /// Clears all visits, or visits at/after the supplied date.
    public func clear(since: Date?) {
        if let since { execute("DELETE FROM visits WHERE last_visit>=?", values: [since.timeIntervalSince1970]) }
        else { execute("DELETE FROM visits") }
    }
    /// Persist a recoverable tab. Closed-tab records are a bounded stack; archives are retained.
    public func addRecovery(_ record: RecoveryRecord, closedLimit: Int = 200) throws {
        try queue.sync {
            guard let db else { throw Self.databaseError(nil) }
            let payload = try JSONEncoder().encode(record)
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw Self.databaseError(db)
            }
            do {
                var statement: OpaquePointer?
                let sql = "INSERT INTO recovery (id,reason,created_at,url,title,payload) VALUES (?,?,?,?,?,?)"
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.databaseError(db) }
                defer { sqlite3_finalize(statement) }
                bind(statement, values: [record.id.uuidString, record.reason.rawValue,
                                         record.createdAt.timeIntervalSince1970, record.saved.url ?? "", record.saved.title])
                _ = payload.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(payload.count),
                                      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.databaseError(db) }
                if record.reason == .closed {
                    var prune: OpaquePointer?
                    guard sqlite3_prepare_v2(db, "DELETE FROM recovery WHERE id IN (SELECT id FROM recovery WHERE reason='closed' ORDER BY created_at DESC LIMIT -1 OFFSET ?)", -1, &prune, nil) == SQLITE_OK else { throw Self.databaseError(db) }
                    sqlite3_bind_int64(prune, 1, Int64(max(0, closedLimit)))
                    let status = sqlite3_step(prune)
                    sqlite3_finalize(prune)
                    guard status == SQLITE_DONE else { throw Self.databaseError(db) }
                }
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw Self.databaseError(db) }
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    public func recovery(reason: RecoveryReason, text: String = "", limit: Int = 100, offset: Int = 0) -> [RecoveryRecord] {
        queue.sync {
            guard let db else { return [] }
            var statement: OpaquePointer?
            let sql = "SELECT payload FROM recovery WHERE reason=? AND (url LIKE ? COLLATE NOCASE OR title LIKE ? COLLATE NOCASE) ORDER BY created_at DESC LIMIT ? OFFSET ?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            bind(statement, values: [reason.rawValue, "%\(text)%", "%\(text)%", max(0, limit), max(0, offset)])
            var result: [RecoveryRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                if let record = try? JSONDecoder().decode(RecoveryRecord.self, from: data) { result.append(record) }
            }
            return result
        }
    }

    public func recovery(id: UUID) -> RecoveryRecord? {
        queue.sync {
            guard let db else { return nil }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload FROM recovery WHERE id=?", -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            bind(statement, values: [id.uuidString])
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            return try? JSONDecoder().decode(RecoveryRecord.self, from: data)
        }
    }

    public func latestClosedRecovery() -> RecoveryRecord? { recovery(reason: .closed, limit: 1).first }

    @discardableResult
    public func deleteRecovery(id: UUID) -> Bool {
        queue.sync {
            guard let db else { return false }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM recovery WHERE id=?", -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }
            bind(statement, values: [id.uuidString])
            return sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0
        }
    }

    public func clearRecovery(reason: RecoveryReason) { execute("DELETE FROM recovery WHERE reason=?", values: [reason.rawValue]) }

    private static func databaseError(_ db: OpaquePointer?) -> NSError {
        NSError(domain: "History", code: 3,
                userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable"])
    }
}
