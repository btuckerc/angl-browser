import XCTest
@testable import AnglCore

final class StoresTests: XCTestCase {
    func testBookmarkFolderAndSearch() {
        var store = BookmarkStore()
        store.add(Bookmark(title: "Example", url: "https://example.com"), toFolderNamed: "Work")
        XCTAssertEqual(store.search("example", limit: 10).count, 1)
        XCTAssertEqual(store.root.first?.title, "Work")
    }

    func testBookmarkFavoritesAreLenientAndPersistInBookmarkTreeOrder() throws {
        let legacy = Data(#"{"id":"00000000-0000-4000-8000-000000000001","title":"Old","url":"https://old.test"}"#.utf8)
        let old = try JSONDecoder().decode(Bookmark.self, from: legacy)
        XCTAssertFalse(old.favorite)

        var store = BookmarkStore(root: [
            Bookmark(title: "Folder", children: [
                Bookmark(title: "First", url: "https://first.test"),
                Bookmark(title: "Second", url: "https://second.test"),
            ])
        ])
        store.setFavorite(true, url: "https://second.test")
        XCTAssertEqual(store.favorites().map(\.url), ["https://second.test"])
        let roundTrip = try JSONDecoder().decode(BookmarkStore.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(roundTrip.favorites().map(\.url), ["https://second.test"])
    }

    func testBookmarkUpdateEditsNestedBookmarkOnly() {
        let first = Bookmark(title: "First", url: "https://first.test")
        let second = Bookmark(title: "Second", url: "https://second.test")
        var store = BookmarkStore(root: [Bookmark(title: "Folder", children: [Bookmark(title: "Inner", children: [first, second])])])
        store.update(id: second.id) { $0.title = "Renamed"; $0.url = "https://renamed.test" }
        XCTAssertEqual(store.flattened().map(\.title), ["First", "Renamed"])
        XCTAssertEqual(store.flattened().map(\.url), ["https://first.test", "https://renamed.test"])
        store.remove(id: first.id)
        XCTAssertEqual(store.flattened().map(\.title), ["Renamed"])
    }

    func testSavedTreeWithoutSplitFieldDecodes() throws {
        let data = Data(#"{"workspaceID":"00000000-0000-4000-8000-000000000001","activeTab":null,"pinned":[],"nodes":[]}"#.utf8)
        let tree = try JSONDecoder().decode(SavedTree.self, from: data)
        XCTAssertNil(tree.split)
    }

    func testHTMLBookmarkImport() {
        let bookmarks = Importers.htmlBookmarks("<DL><p><DT><A HREF=\"https://a.test\">A</A></DL>")
        XCTAssertEqual(bookmarks.first?.url, "https://a.test")
    }

    func testQueuedVisitWritesAreVisibleToImmediateReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let page = URL(string: "https://example.test/a")!
        store.record(url: page, title: "Old", typed: false)
        store.record(url: page, title: "Old", typed: true)
        store.updateTitle(url: page, title: "New")
        store.record(url: URL(string: "about:blank")!, title: nil, typed: false)
        let items = store.query("", limit: 10, offset: 0)
        XCTAssertEqual(items.map(\.url), [page.absoluteString])
        XCTAssertEqual(items.first?.title, "New")
        XCTAssertEqual(items.first?.visits, 2)
        XCTAssertEqual(store.suggest("example", limit: 5).map(\.url), [page.absoluteString])
    }

    func testRecoveryTableRoundTripsAndConsumesRecords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let node = TabNode.tab(URL(string: "https://example.test/path")!, title: "Example",
                               containerID: UUID())
        node.interactionState = Data([1, 2, 3])
        let record = RecoveryRecord(saved: SavedNode(node), workspaceID: UUID(), parentID: UUID(),
                                    index: 4, reason: .archived, createdAt: Date(timeIntervalSince1970: 123))
        try store.addRecovery(record)
        XCTAssertEqual(store.recovery(reason: .archived, text: "example"), [record])
        XCTAssertEqual(store.recovery(reason: .closed), [])
        XCTAssertTrue(store.deleteRecovery(id: record.id))
        XCTAssertEqual(store.recovery(reason: .archived), [])
    }
}
