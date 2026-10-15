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

    func testMatchesSortByName() {
        let a = LoginIndex.Login(id: "a", name: "item 10", username: "", hasTOTP: false, reprompt: false)
        let b = LoginIndex.Login(id: "b", name: "Item 9", username: "", hasTOTP: false, reprompt: false)
        let c = LoginIndex.Login(id: "c", name: "elsewhere", username: "", hasTOTP: false, reprompt: false)
        let idx = LoginIndex([(a, [.init("example.com")]), (b, [.init("example.com")]), (c, [.init("other.com")])])
        XCTAssertEqual(idx.matches(for: URL(string: "https://example.com/")!).map(\.id), ["b", "a"])
    }
}
