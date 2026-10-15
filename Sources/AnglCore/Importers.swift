import Foundation
import SQLite3

/// Import helpers for browser bookmark and history exports.
public enum Importers {
    /// Imports Safari's Bookmarks.plist.
    public static func safariBookmarks(plist: URL) throws -> [Bookmark] {
        let data = try Data(contentsOf: plist)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = object as? [String: Any] else { return [] }
        func parse(_ node: [String: Any]) -> Bookmark? {
            let type = node["WebBookmarkType"] as? String ?? ""
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
            if type == "WebBookmarkTypeLeaf", let url = node["URLString"] as? String {
                return Bookmark(title: title, url: url)
            }
            guard type == "WebBookmarkTypeList", title != "com.apple.ReadingList" else { return nil }
            let children = (node["Children"] as? [[String: Any]] ?? []).compactMap(parse)
            return Bookmark(title: title, children: children)
        }
        return (root["Children"] as? [[String: Any]] ?? []).compactMap(parse)
    }

    /// Imports Chrome's Bookmarks JSON file.
    public static func chromeBookmarks(json: URL) throws -> [Bookmark] {
        let data = try Data(contentsOf: json)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        func parse(_ node: [String: Any]) -> Bookmark? {
            let title = node["name"] as? String ?? ""
            if let value = node["url"] as? [String: Any], let url = value["url"] as? String {
                return Bookmark(title: title, url: url)
            }
            let children = (node["children"] as? [[String: Any]] ?? []).compactMap(parse)
            return Bookmark(title: title, children: children)
        }
        let roots = object["roots"] as? [String: Any] ?? [:]
        return ["bookmark_bar", "other", "synced"].compactMap { roots[$0] as? [String: Any] }.compactMap(parse)
    }

    /// Parses Netscape-format HTML bookmarks.
    public static func htmlBookmarks(_ html: String) -> [Bookmark] {
        var folders: [(String, [Bookmark])] = []
        var root: [Bookmark] = []
        for line in html.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if let range = value.range(of: "<H3[^>]*>(.*?)</H3>", options: [.regularExpression, .caseInsensitive]) {
                let title = String(value[range]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                folders.append((title, []))
            } else if value.range(of: "<A\\s", options: [.regularExpression, .caseInsensitive]) != nil,
                      let href = value.range(of: "HREF=[\"']([^\"']+)[\"']", options: [.regularExpression, .caseInsensitive]) {
                let attribute = String(value[href])
                let url = attribute.replacingOccurrences(of: "^HREF=[\"']|[\"']$", with: "", options: .regularExpression)
                let title = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let item = Bookmark(title: title, url: url)
                if !folders.isEmpty { folders[folders.count - 1].1.append(item) } else { root.append(item) }
            } else if value.uppercased().contains("</DL>") && !folders.isEmpty {
                let (title, children) = folders.removeLast()
                let folder = Bookmark(title: title, children: children)
                if !folders.isEmpty { folders[folders.count - 1].1.append(folder) } else { root.append(folder) }
            }
        }
        return root
    }

    /// Imports Chrome history, copying the live database before querying it.
    public static func chromeHistory(sqlite: URL) throws -> [(url: String, title: String, visits: Int, lastVisit: Date)] {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: sqlite, to: copy)
        var database: OpaquePointer?
        guard sqlite3_open(copy.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "Chrome history", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open Chrome history database"])
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT url,title,visit_count,last_visit_time FROM urls", -1,
                                 &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "Chrome history", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Chrome history database"])
        }
        defer { sqlite3_finalize(statement) }
        var rows: [(url: String, title: String, visits: Int, lastVisit: Date)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let micros = sqlite3_column_int64(statement, 3)
            let date = Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
            rows.append((String(cString: sqlite3_column_text(statement, 0)),
                         String(cString: sqlite3_column_text(statement, 1)),
                         Int(sqlite3_column_int(statement, 2)), date))
        }
        return rows
    }
}
