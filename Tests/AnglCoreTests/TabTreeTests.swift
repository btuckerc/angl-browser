import AnglCore
import XCTest

final class TabTreeTests: XCTestCase {
    private func tab(_ title: String) -> TabNode { TabNode.tab(URL(string: "https://\(title).test")!, title: title) }

    func testClosingParentPromotesChildrenInPlace() {
        let t = TabTree()
        let a = tab("a"), b = tab("b"), c = tab("c"), d = tab("d")
        t.insert(a); t.insert(b, under: a); t.insert(c, under: a); t.insert(d)
        t.remove(a)
        XCTAssertEqual(t.root.children.map(\.title), ["b", "c", "d"])
        XCTAssertTrue(b.parent === t.root)
    }

    func testRemoveSubtreeReturnsEveryTab() {
        let t = TabTree()
        let a = tab("a"), b = tab("b"), c = tab("c")
        t.insert(a); t.insert(b, under: a); t.insert(c, under: b)
        XCTAssertEqual(Set(t.removeSubtree(a).map(\.title)), ["a", "b", "c"])
        XCTAssertTrue(t.isEmpty)
    }

    func testSuccessorPrefersPreviousSiblingThenChildThenNextThenParent() {
        let t = TabTree()
        let p = tab("p"), x = tab("x"), y = tab("y"), yk = tab("yk"), z = tab("z")
        t.insert(p); t.insert(x, under: p); t.insert(y, under: p); t.insert(yk, under: y); t.insert(z, under: p)
        XCTAssertTrue(t.successor(of: y) === x)
        XCTAssertTrue(t.successor(of: x) === y)
        t.removeSubtree(x)
        XCTAssertTrue(t.successor(of: y) === yk, "promoted child is next")
        XCTAssertTrue(t.successor(of: y, closingSubtree: true) === z)
        t.removeSubtree(y); t.removeSubtree(z)
        XCTAssertTrue(t.successor(of: p) == nil)
    }

    func testGroupKeepsSubtreesAndPosition() {
        let t = TabTree()
        let a = tab("a"), b = tab("b"), bk = tab("bk"), c = tab("c")
        t.insert(a); t.insert(b); t.insert(bk, under: b); t.insert(c)
        let f = t.group([b, bk, c], name: "f")!
        XCTAssertEqual(t.root.children.map(\.title), ["a", "f"])
        XCTAssertEqual(f.children.map(\.title), ["b", "c"])
        XCTAssertEqual(b.children.map(\.title), ["bk"])
        t.ungroup(f)
        XCTAssertEqual(t.root.children.map(\.title), ["a", "b", "c"])
    }

    func testPinningLiftsChildrenIntoTree() {
        let t = TabTree()
        let a = tab("a"), b = tab("b")
        t.insert(a); t.insert(b, under: a)
        t.pin(a)
        XCTAssertEqual(t.pinned.map(\.title), ["a"])
        XCTAssertEqual(t.root.children.map(\.title), ["b"])
        XCTAssertEqual(t.allTabs.map(\.title), ["a", "b"])
    }

    func testInsertAfterSiblingWhenMovingDownwardKeepsOrder() {
        let t = TabTree()
        let a = tab("a"), b = tab("b"), c = tab("c")
        t.insert(a); t.insert(b); t.insert(c)
        t.insert(a, after: b)
        XCTAssertEqual(t.root.children.map(\.title), ["b", "a", "c"])
    }

    func testRoundTripPreservesStructure() throws {
        let t = TabTree()
        let a = tab("a"), b = tab("b"), pin = tab("pin")
        t.insert(a); t.insert(b, under: a); t.pin(pin)
        a.collapsed = true
        let saved = SavedTree(workspaceID: UUID(), tree: t, activeTab: b.id)
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode(SavedTree.self, from: data).makeTree()
        XCTAssertEqual(back.pinned.map(\.title), ["pin"])
        XCTAssertEqual(back.root.children.first?.children.map(\.title), ["b"])
        XCTAssertEqual(back.root.children.first?.collapsed, true)
        XCTAssertEqual(saved.tabCount, 3)
    }
}
