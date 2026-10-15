import Foundation

/// A bookmark or folder; folders have no URL.
public struct Bookmark: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: String?
    public var children: [Bookmark]?
    public var favorite = false

    private enum CodingKeys: String, CodingKey { case id, title, url, children, favorite }

    public init(id: UUID = UUID(), title: String, url: String? = nil, children: [Bookmark]? = nil, favorite: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.children = children
        self.favorite = favorite
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        children = try values.decodeIfPresent([Bookmark].self, forKey: .children)
        favorite = try values.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
    }
}

/// Persistent hierarchical bookmarks.
public struct BookmarkStore: Codable, Sendable {
    public var root: [Bookmark]

    public init(root: [Bookmark] = []) { self.root = root }
    public static func load(from url: URL) throws -> BookmarkStore { try JSONFile.read(Self.self, from: url) ?? Self() }
    public func save(to url: URL) throws { try JSONFile.write(self, to: url) }

    /// Adds a bookmark to the named folder, creating that folder if needed.
    public mutating func add(_ bookmark: Bookmark, toFolderNamed name: String? = nil) {
        guard let name else { root.append(bookmark); return }
        func append(_ items: inout [Bookmark]) -> Bool {
            if let index = items.firstIndex(where: { $0.title == name && $0.url == nil }) {
                items[index].children = (items[index].children ?? []) + [bookmark]
                return true
            }
            for index in items.indices {
                var children = items[index].children ?? []
                if append(&children) { items[index].children = children; return true }
            }
            return false
        }
        if !append(&root) { root.append(Bookmark(title: name, children: [bookmark])) }
    }

    /// Removes a bookmark or folder recursively.
    public mutating func remove(id: UUID) {
        func removeItem(_ items: inout [Bookmark]) {
            items.removeAll { $0.id == id }
            for index in items.indices {
                guard items[index].children != nil else { continue }
                var children = items[index].children!
                removeItem(&children)
                items[index].children = children
            }
        }
        removeItem(&root)
    }

    /// Returns all leaf bookmarks in tree order.
    public func flattened() -> [Bookmark] {
        func flatten(_ items: [Bookmark]) -> [Bookmark] {
            items.flatMap { $0.url != nil ? [$0] : flatten($0.children ?? []) }
        }
        return flatten(root)
    }
    /// Leaf bookmarks marked as Favorites, preserving bookmark order.
    public func favorites() -> [Bookmark] { flattened().filter(\.favorite) }

    /// Updates favorite metadata for the bookmark matching an exact URL.
    public mutating func setFavorite(_ favorite: Bool, url: String) {
        guard let id = flattened().first(where: { $0.url == url })?.id else { return }
        update(id: id) { $0.favorite = favorite }
    }

    /// Applies `change` to the bookmark or folder with `id`, at any depth.
    public mutating func update(id: UUID, _ change: (inout Bookmark) -> Void) {
        func walk(_ items: inout [Bookmark]) -> Bool {
            for index in items.indices {
                if items[index].id == id { change(&items[index]); return true }
                if var children = items[index].children, walk(&children) { items[index].children = children; return true }
            }
            return false
        }
        _ = walk(&root)
    }

    /// Searches leaf titles and URLs for every term.
    public func search(_ text: String, limit: Int) -> [Bookmark] {
        let terms = text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return flattened().filter { bookmark in
            let value = (bookmark.title + " " + (bookmark.url ?? "")).lowercased()
            return terms.allSatisfy { value.contains($0) }
        }.prefix(max(0, limit)).map { $0 }
    }
}
