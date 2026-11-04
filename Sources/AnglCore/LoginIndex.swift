import Foundation
import PublicSuffixList

/// A vault's logins with Bitwarden's URI match rules precomputed, so finding the logins for a
/// page is a scan of set lookups. Rules follow Bitwarden's clients (LoginUriView.matchesUri):
/// Domain compares registrable domains (public suffix list, private suffixes included), widened
/// by the account's equivalent domains; Host compares host[:port]; StartsWith and Exact compare
/// the page URL string; RegularExpression is case-insensitive; Never never matches.
/// Which logins match is Bitwarden's call; how they rank (`Match.Tier`) is angl's.
public struct LoginIndex: Sendable {
    public enum Rule: Int, Sendable { case domain, host, startsWith, exact, regularExpression, never }

    public struct Login: Sendable, Equatable {
        public let id: String
        public let name: String
        public let username: String
        public let hasTOTP: Bool
        /// Bitwarden's "master password re-prompt".
        public let reprompt: Bool
        /// Holds a passkey (Bitwarden keeps at most one per login).
        public let hasPasskey: Bool
        public let favorite: Bool

        public init(id: String, name: String, username: String, hasTOTP: Bool, reprompt: Bool, hasPasskey: Bool = false, favorite: Bool = false) {
            self.id = id; self.name = name; self.username = username; self.hasTOTP = hasTOTP; self.reprompt = reprompt
            self.hasPasskey = hasPasskey; self.favorite = favorite
        }

        /// What the login is called in lists: its name, else its username.
        public var title: String { name.isEmpty ? username : name }
    }

    public struct URI: Sendable {
        public let uri: String
        /// nil = the default rule (Domain).
        public let rule: Rule?

        public init(_ uri: String, rule: Rule? = nil) { self.uri = uri; self.rule = rule }
    }

    /// A login that matches a page, with how closely.
    public struct Match: Sendable, Equatable {
        /// How closely the login's best-fitting URI fits the page; strongest first.
        public enum Tier: Int, Sendable, Comparable {
            /// A URI on the page's host (and port).
            case host
            /// The page's host on another port, or with/without a leading "www.".
            case nearHost
            /// A StartsWith, Exact or regular-expression URI that names no host of this page.
            case rule
            /// Another host on the page's registrable domain.
            case domain
            /// A domain the account treats as equivalent to the page's.
            case equivalent

            public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
        }

        public let login: Login
        public let tier: Tier
        /// host[:port] of the URI that matched, when it names one.
        public let host: String?
    }

    /// Orders logins within a tier.
    public struct Ranking: Sendable {
        /// Login ID → when it was last filled (seconds since 1970); newer first.
        public var lastUsed: [String: Double]
        /// A username the page already shows (a password step): logins with it go first.
        public var username: String?

        public init(lastUsed: [String: Double] = [:], username: String? = nil) { self.lastUsed = lastUsed; self.username = username }
    }

    private struct Target: @unchecked Sendable {  // NSRegularExpression is immutable
        let uri: String
        let rule: Rule
        let domain: String?
        /// Host without port.
        let name: String?
        /// host[:non-default port].
        let host: String?
        let regex: NSRegularExpression?
    }

    public let logins: [Login]
    private let targets: [[Target]]
    private let equivalents: [String: Set<String>]
    /// Lowercased name, username and URI hosts per login, for search.
    private let haystacks: [[String]]
    private let positions: [String: Int]

    public init(_ entries: [(Login, [URI])], equivalentDomains: [[String]] = []) {
        logins = entries.map(\.0)
        targets = entries.map { _, uris in
            uris.map { u in
                let rule = u.rule ?? .domain
                let parsed = rule == .regularExpression || rule == .never ? nil : Self.parse(u.uri)
                return Target(uri: u.uri, rule: rule, domain: parsed.flatMap { Self.domain(of: $0.host) }, name: parsed?.host,
                              host: parsed.map(\.hostPort),
                              regex: rule == .regularExpression ? try? NSRegularExpression(pattern: u.uri, options: .caseInsensitive) : nil)
            }
        }
        haystacks = zip(logins, targets).map { login, targets in
            [login.name.lowercased(), login.username.lowercased()] + targets.compactMap(\.name)
        }
        positions = Dictionary(logins.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var eq: [String: Set<String>] = [:]
        for group in equivalentDomains {
            let set = Set(group.map { $0.lowercased() })
            for d in set { eq[d, default: []].formUnion(set) }
        }
        equivalents = eq
    }

    /// Logins with at least one URI matching `url`: by tier, then the page's username, last
    /// use, favorites, name, username.
    public func matches(for url: URL, ranking: Ranking = .init()) -> [Match] {
        let page = url.absoluteString
        let parsed = Self.parse(page)
        let pageDomain = parsed.flatMap { Self.domain(of: $0.host) }
        let domains = pageDomain.map { equivalents[$0, default: []].union([$0]) } ?? []
        let pageHost = parsed?.hostPort, pageName = parsed?.host
        let range = NSRange(page.startIndex..., in: page)
        func tier(_ t: Target) -> (Match.Tier, String?)? {
            switch t.rule {
            case .domain:
                guard let d = t.domain, domains.contains(d), !(Self.domainExceptions[d]?.contains(pageName ?? "") ?? false) else { return nil }
                if t.host == pageHost { return (.host, t.host) }
                if let n = t.name, let p = pageName, n == p || n == "www." + p || p == "www." + n { return (.nearHost, t.host) }
                return (d == pageDomain ? .domain : .equivalent, t.host)
            case .host:
                return pageHost != nil && t.host == pageHost ? (.host, t.host) : nil
            case .startsWith, .exact:
                guard t.rule == .exact ? page == t.uri : page.hasPrefix(t.uri) else { return nil }
                return (t.host != nil && t.host == pageHost ? .host : .rule, t.host)
            case .regularExpression:
                return t.regex?.firstMatch(in: page, range: range) != nil ? (.rule, nil) : nil
            case .never:
                return nil
            }
        }
        let found: [Match] = zip(logins, targets).compactMap { login, targets in
            guard let best = targets.compactMap(tier).min(by: { $0.0 < $1.0 }) else { return nil }
            return Match(login: login, tier: best.0, host: best.1)
        }
        let username = ranking.username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return found.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if let username, !username.isEmpty {
                let ua = a.login.username.lowercased() == username, ub = b.login.username.lowercased() == username
                if ua != ub { return ua }
            }
            return Self.before(a.login, b.login, ranking.lastUsed)
        }
    }

    /// Logins whose name, username or URI hosts contain every word of `query` (case-insensitive):
    /// word-start matches first, then last use, favorites, name.
    public func search(_ query: String, lastUsed: [String: Double] = [:], limit: Int = 200) -> [Login] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var scored: [(score: Int, login: Login)] = []
        for (i, fields) in haystacks.enumerated() {
            var score = 0
            for word in words {
                var best = 0
                for f in fields {
                    guard let r = f.range(of: word) else { continue }
                    let start = r.lowerBound == f.startIndex || !f[f.index(before: r.lowerBound)].isLetter && !f[f.index(before: r.lowerBound)].isNumber
                    best = max(best, start ? 2 : 1)
                    if best == 2 { break }
                }
                guard best > 0 else { score = 0; break }
                score += best
            }
            if score > 0 { scored.append((score, logins[i])) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : Self.before(a.login, b.login, lastUsed) }
        return scored.prefix(limit).map(\.login)
    }

    /// The host of a login's first URI that names one, for showing where it belongs.
    public func site(of id: String) -> String? {
        positions[id].flatMap { targets[$0].lazy.compactMap(\.host).first }
    }

    /// Last use, then favorites, name, username, ID: a total order, so lists never shuffle.
    private static func before(_ a: Login, _ b: Login, _ lastUsed: [String: Double]) -> Bool {
        let ta = lastUsed[a.id] ?? 0, tb = lastUsed[b.id] ?? 0
        if ta != tb { return ta > tb }
        if a.favorite != b.favorite { return a.favorite }
        switch a.title.localizedStandardCompare(b.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: break
        }
        if a.username != b.username { return a.username.localizedStandardCompare(b.username) == .orderedAscending }
        return a.id < b.id
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
    public static func domain(of host: String) -> String? {
        if host == "localhost" || host.contains(":") || host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return host }
        return PublicSuffixList.effectiveTLDPlusOne(host)
    }
}
