import Foundation
import PublicSuffixList

/// A vault's logins with Bitwarden's URI match rules precomputed, so finding the logins for a
/// page is a scan of set lookups. Rules follow Bitwarden's clients (LoginUriView.matchesUri):
/// Domain compares registrable domains (public suffix list, private suffixes included), widened
/// by the account's equivalent domains; Host compares host[:port]; StartsWith and Exact compare
/// the page URL string; RegularExpression is case-insensitive; Never never matches.
public struct LoginIndex: Sendable {
    public enum Rule: Int, Sendable { case domain, host, startsWith, exact, regularExpression, never }

    public struct Login: Sendable, Equatable {
        public let id: String
        public let name: String
        public let username: String
        public let hasTOTP: Bool
        /// Bitwarden's "master password re-prompt".
        public let reprompt: Bool

        public init(id: String, name: String, username: String, hasTOTP: Bool, reprompt: Bool) {
            self.id = id; self.name = name; self.username = username; self.hasTOTP = hasTOTP; self.reprompt = reprompt
        }
    }

    public struct URI: Sendable {
        public let uri: String
        /// nil = the default rule (Domain).
        public let rule: Rule?

        public init(_ uri: String, rule: Rule? = nil) { self.uri = uri; self.rule = rule }
    }

    private struct Target: @unchecked Sendable {  // NSRegularExpression is immutable
        let uri: String
        let rule: Rule
        let domain: String?
        let host: String?
        let regex: NSRegularExpression?
    }

    public let logins: [Login]
    private let targets: [[Target]]
    private let equivalents: [String: Set<String>]

    public init(_ entries: [(Login, [URI])], equivalentDomains: [[String]] = []) {
        logins = entries.map(\.0)
        targets = entries.map { _, uris in
            uris.map { u in
                let rule = u.rule ?? .domain
                let parsed = rule == .domain || rule == .host ? Self.parse(u.uri) : nil
                return Target(uri: u.uri, rule: rule, domain: parsed.flatMap { Self.domain(of: $0.host) },
                              host: parsed.map(\.hostPort),
                              regex: rule == .regularExpression ? try? NSRegularExpression(pattern: u.uri, options: .caseInsensitive) : nil)
            }
        }
        var eq: [String: Set<String>] = [:]
        for group in equivalentDomains {
            let set = Set(group.map { $0.lowercased() })
            for d in set { eq[d, default: []].formUnion(set) }
        }
        equivalents = eq
    }

    /// Logins with at least one URI matching `url`, by name.
    public func matches(for url: URL) -> [Login] {
        let page = url.absoluteString
        let parsed = Self.parse(page)
        let pageDomain = parsed.flatMap { Self.domain(of: $0.host) }
        let domains = pageDomain.map { equivalents[$0, default: []].union([$0]) } ?? []
        let pageHost = parsed?.hostPort
        let range = NSRange(page.startIndex..., in: page)
        return zip(logins, targets).filter { _, targets in
            targets.contains { t in
                switch t.rule {
                case .domain:
                    guard let d = t.domain, domains.contains(d) else { return false }
                    return !(Self.domainExceptions[d]?.contains(parsed?.host ?? "") ?? false)
                case .host: return pageHost != nil && t.host == pageHost
                case .startsWith: return page.hasPrefix(t.uri)
                case .exact: return page == t.uri
                case .regularExpression: return t.regex?.firstMatch(in: page, range: range) != nil
                case .never: return false
                }
            }
        }
        .map(\.0)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Hosts Bitwarden never fills from a registrable-domain match (Utils.DomainMatchBlacklist).
    private static let domainExceptions: [String: Set<String>] = ["google.com": ["script.google.com"]]

    private static let defaultPorts: [String: Int] = ["http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21]

    /// Host and host[:non-default port]. Like Bitwarden, a URI without "://" is read as http://
    /// when it names a dotted host or localhost.
    static func parse(_ string: String) -> (host: String, hostPort: String)? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemeless = !s.contains("://")
        guard let url = URL(string: schemeless ? "http://" + s : s), let host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty, !schemeless || host.contains(".") || host == "localhost" else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port.flatMap { $0 == defaultPorts[scheme] ? nil : $0 }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return (host, port.map { "\(bracketed):\($0)" } ?? bracketed)
    }

    /// Registrable domain; IP addresses and localhost stand for themselves; nil for a bare
    /// public suffix or a single unknown label.
    static func domain(of host: String) -> String? {
        if host == "localhost" || host.contains(":") || host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return host }
        return PublicSuffixList.effectiveTLDPlusOne(host)
    }
}
