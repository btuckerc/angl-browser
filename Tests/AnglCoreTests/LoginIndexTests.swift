import Foundation
import XCTest
@testable import AnglCore

final class LoginIndexTests: XCTestCase {
    private func index(_ uris: [LoginIndex.URI], equivalent: [[String]] = []) -> LoginIndex {
        let login = LoginIndex.Login(id: "1", name: "n", username: "u", hasTOTP: false, reprompt: false)
        return LoginIndex([(login, uris)], equivalentDomains: equivalent)
    }

    private func matches(_ uris: [LoginIndex.URI], _ page: String, equivalent: [[String]] = []) -> Bool {
        !index(uris, equivalent: equivalent).matches(for: URL(string: page)!).isEmpty
    }

    func testDomainRuleMatchesSubdomainsAndPortsButNotOtherSites() {
        let uri = [LoginIndex.URI("https://example.co.uk/login")]
        XCTAssertTrue(matches(uri, "https://accounts.example.co.uk:8443/x"))
        XCTAssertTrue(matches([LoginIndex.URI("example.co.uk")], "https://www.example.co.uk/"))
        XCTAssertFalse(matches(uri, "https://example-co.uk/"))
        XCTAssertFalse(matches(uri, "https://other.co.uk/"))
    }

    func testPrivateSuffixesSeparateTenants() {
        XCTAssertFalse(matches([LoginIndex.URI("https://alice.github.io")], "https://mallory.github.io/"))
        XCTAssertTrue(matches([LoginIndex.URI("https://alice.github.io")], "https://alice.github.io/repo"))
    }

    func testEquivalentDomainsWidenOnlyTheDomainRule() {
        let eq = [["ameritrade.com", "tdameritrade.com"]]
        XCTAssertTrue(matches([LoginIndex.URI("https://ameritrade.com")], "https://www.tdameritrade.com/", equivalent: eq))
        XCTAssertFalse(matches([LoginIndex.URI("https://ameritrade.com", rule: .host)], "https://tdameritrade.com/", equivalent: eq))
    }

    func testHostRuleComparesHostAndNonDefaultPort() {
        let uri = [LoginIndex.URI("https://app.example.com:8444/a", rule: .host)]
        XCTAssertTrue(matches(uri, "https://app.example.com:8444/b"))
        XCTAssertFalse(matches(uri, "https://app.example.com/b"))
        XCTAssertFalse(matches(uri, "https://www.example.com:8444/b"))
        XCTAssertTrue(matches([LoginIndex.URI("https://app.example.com:443", rule: .host)], "https://app.example.com/"))
    }

    func testStringRules() {
        XCTAssertTrue(matches([LoginIndex.URI("https://example.com/login", rule: .startsWith)], "https://example.com/login?next=/"))
        XCTAssertFalse(matches([LoginIndex.URI("https://example.com/login", rule: .startsWith)], "https://example.com/"))
        XCTAssertTrue(matches([LoginIndex.URI("https://example.com/a", rule: .exact)], "https://example.com/a"))
        XCTAssertFalse(matches([LoginIndex.URI("https://example.com/a", rule: .exact)], "https://example.com/a?b"))
        XCTAssertTrue(matches([LoginIndex.URI(#"^https://[a-z]+\.EXAMPLE\.com/"#, rule: .regularExpression)], "https://shop.example.com/"))
        XCTAssertFalse(matches([LoginIndex.URI("(", rule: .regularExpression)], "https://example.com/"))
    }

    func testNeverRuleExcludesOnlyItsOwnURI() {
        XCTAssertFalse(matches([LoginIndex.URI("https://example.com", rule: .never)], "https://example.com/"))
        XCTAssertTrue(matches([LoginIndex.URI("https://example.com", rule: .never), LoginIndex.URI("https://example.com/login", rule: .startsWith)],
                              "https://example.com/login"))
    }

    func testAddressesAndBlockedHosts() {
        XCTAssertTrue(matches([LoginIndex.URI("http://192.168.1.10:8080")], "https://192.168.1.10/"))
        XCTAssertFalse(matches([LoginIndex.URI("http://192.168.1.10")], "https://192.168.1.11/"))
        XCTAssertTrue(matches([LoginIndex.URI("localhost:3000")], "http://localhost:5173/"))
        XCTAssertFalse(matches([LoginIndex.URI("https://accounts.google.com")], "https://script.google.com/home"))
        XCTAssertTrue(matches([LoginIndex.URI("https://accounts.google.com")], "https://mail.google.com/"))
    }

    private func login(_ id: String, _ name: String, _ username: String = "", favorite: Bool = false) -> LoginIndex.Login {
        LoginIndex.Login(id: id, name: name, username: username, hasTOTP: false, reprompt: false, favorite: favorite)
    }

    private func ranked(_ idx: LoginIndex, _ page: String, _ ranking: LoginIndex.Ranking = .init()) -> [String] {
        idx.matches(for: URL(string: page)!, ranking: ranking).map(\.login.id)
    }

    func testThisHostOutranksSiblingServicesOnTheSameDomain() {
        let idx = LoginIndex([
            (login("gitea", "Gitea"), [.init("https://git.example.com")]),
            (login("mail", "Mail"), [.init("example.com")]),
            (login("grafana", "Grafana"), [.init("https://grafana.example.com/login")]),
            (login("www", "Grafana www"), [.init("https://www.grafana.example.com")]),
            (login("port", "Grafana alt port"), [.init("https://grafana.example.com:3000")]),
        ])
        let found = idx.matches(for: URL(string: "https://grafana.example.com/login")!)
        XCTAssertEqual(found.map(\.login.id), ["grafana", "port", "www", "gitea", "mail"])
        XCTAssertEqual(found.map(\.tier), [.host, .nearHost, .nearHost, .domain, .domain])
        XCTAssertEqual(found.map(\.host), ["grafana.example.com", "grafana.example.com:3000", "www.grafana.example.com", "git.example.com", "example.com"])
    }

    func testALoginRanksByItsBestMatchingURI() {
        let idx = LoginIndex([
            (login("a", "A"), [.init("https://other.example.com")]),
            (login("b", "B"), [.init("https://other.example.com"), .init("https://app.example.com", rule: .host), .init("https://app.example.com", rule: .never)]),
        ])
        XCTAssertEqual(ranked(idx, "https://app.example.com/"), ["b", "a"])
    }

    func testRulesWithoutThisHostRankBetweenNearHostsAndSiblings() {
        let idx = LoginIndex([
            (login("sibling", "Sibling"), [.init("https://www.example.com")]),
            (login("regex", "Regex"), [.init(#"^https://[a-z]+\.example\.com/"#, rule: .regularExpression)]),
            (login("prefix", "Prefix"), [.init("https://app.example.com/sign", rule: .startsWith)]),
        ])
        let found = idx.matches(for: URL(string: "https://app.example.com/sign-in")!)
        XCTAssertEqual(found.map(\.login.id), ["prefix", "regex", "sibling"])
        XCTAssertEqual(found.map(\.tier), [.host, .rule, .domain])
    }

    func testEquivalentDomainsRankLast() {
        let idx = LoginIndex([
            (login("eq", "Equivalent"), [.init("https://youtube.com")]),
            (login("sib", "Sibling"), [.init("https://mail.google.com")]),
        ], equivalentDomains: [["google.com", "youtube.com"]])
        let found = idx.matches(for: URL(string: "https://accounts.google.com/")!)
        XCTAssertEqual(found.map(\.login.id), ["sib", "eq"])
        XCTAssertEqual(found.last?.tier, .equivalent)
    }

    func testWithinATierShownUsernameThenLastUseThenFavoriteThenName() {
        let uri = [LoginIndex.URI("https://example.com")]
        let idx = LoginIndex([
            (login("b", "Item 9", "bob"), uri), (login("a", "item 10", "amy"), uri),
            (login("fav", "Zed", "zed", favorite: true), uri), (login("used", "Yak", "yak"), uri),
        ])
        let page = "https://example.com/"
        XCTAssertEqual(ranked(idx, page), ["fav", "b", "a", "used"])
        XCTAssertEqual(ranked(idx, page, .init(lastUsed: ["used": 20, "a": 10])), ["used", "a", "fav", "b"])
        XCTAssertEqual(ranked(idx, page, .init(lastUsed: ["used": 20], username: " BOB ")), ["b", "used", "fav", "a"])
    }

    func testTierBeatsRecencyAndFavorites() {
        let idx = LoginIndex([
            (login("sib", "Sibling", favorite: true), [.init("https://other.example.com")]),
            (login("here", "Here"), [.init("https://app.example.com")]),
        ])
        XCTAssertEqual(ranked(idx, "https://app.example.com/", .init(lastUsed: ["sib": 99])), ["here", "sib"])
    }

    func testSearchNeedsEveryWordAndPrefersWordStarts() {
        let idx = LoginIndex([
            (login("1", "Grafana", "tucker"), [.init("https://grafana.example.com")]),
            (login("2", "Jellyfin", "tucker"), [.init("https://media.example.com")]),
            (login("3", "Instagram", "admin"), [.init("https://social.example.org")]),
            (login("4", "Status", "admin"), [.init("https://example.org/status")]),
        ])
        XCTAssertEqual(idx.search("tuck graf").map(\.id), ["1"])
        XCTAssertEqual(idx.search("media").map(\.id), ["2"], "URI hosts are searchable")
        XCTAssertEqual(idx.search("sta").map(\.id), ["4", "3"], "a word start outranks a match inside a word")
        XCTAssertEqual(idx.search("ADMIN", lastUsed: ["4": 5]).map(\.id), ["4", "3"])
        XCTAssertEqual(idx.search("  ").map(\.id), [])
        XCTAssertEqual(idx.site(of: "4"), "example.org")
    }

    func testUsageKeepsOnlyIDsAndTimesPrivately() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("usage.json")
        var usage = LoginUsage(file: file)
        usage.record("a", at: Date(timeIntervalSince1970: 10))
        usage.record("b", at: Date(timeIntervalSince1970: 20))
        usage.prune(keeping: ["b"])
        XCTAssertEqual(LoginUsage(file: file).lastUsed, ["b": 20])
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
