import Foundation

/// What the URL field / palette input means.
public enum OmniboxInput: Equatable, Sendable {
    case navigate(URL)
    case command(String)
    /// Restrict suggestions: "t " tabs, "h " history, "b " bookmarks, "a " archived tabs.
    case filter(Scope, String)
    case empty

    public enum Scope: String, Sendable { case tabs = "t", history = "h", bookmarks = "b", archive = "a" }
}

public enum Omnibox {
    public static func parse(_ raw: String, settings: Settings.Search) -> OmniboxInput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        if text.hasPrefix(">") {
            return .command(String(text.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        if let space = text.firstIndex(of: " ") {
            let head = String(text[..<space])
            let rest = String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            if let scope = OmniboxInput.Scope(rawValue: head) { return .filter(scope, rest) }
            if let template = settings.keywords[head], !rest.isEmpty,
               let url = Settings.searchURL(template: template, query: rest) {
                return .navigate(url)
            }
        }
        if let url = urlIfAddress(text) { return .navigate(url) }
        return Settings.searchURL(template: settings.engine, query: text).map(OmniboxInput.navigate) ?? .empty
    }

    /// Treat input as an address when it has a scheme we handle, or looks like host[:port][/path]
    /// with a dot or is localhost / an IP. Anything with a space is a search.
    public static func urlIfAddress(_ text: String) -> URL? {
        guard !text.contains(" ") else { return nil }
        let lower = text.lowercased()
        for scheme in ["http://", "https://", "angl:", "file://", "about:", "data:"] where lower.hasPrefix(scheme) {
            return URL(string: text)
        }
        if lower.hasPrefix("view-source:") { return nil }
        // host[:port][/...]
        let hostPart = lower.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? lower
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let isIP = host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
        let hasPort = hostPart.range(of: #":\d{1,5}$"#, options: .regularExpression) != nil
        let tld = host.split(separator: ".").last.map(String.init) ?? ""
        let looksLikeDomain = host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
            && tld.range(of: #"^[a-z][a-z0-9-]{1,62}$"#, options: .regularExpression) != nil
            && host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
        guard looksLikeDomain || isIP || host == "localhost" || (hasPort && !host.isEmpty) else { return nil }
        let local = isIP || host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".i2p") || hasPort
        return URL(string: (local ? "http://" : "https://") + text)
    }

    /// What the URL field shows for a page: no scheme for http(s), no trailing slash on bare hosts.
    public static func display(_ url: URL) -> String {
        var s = url.absoluteString
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasSuffix("/"), s.filter({ $0 == "/" }).count == 1 { s.removeLast() }
        return s
    }
}

/// Tracking-parameter stripping for navigations and copied URLs.
public enum CleanURL {
    static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid", "twclid",
        "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "wickedid", "ttclid", "srsltid",
    ]

    public static func clean(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = c.queryItems,
              !items.isEmpty else { return url }
        let kept = items.filter { item in
            let n = item.name.lowercased()
            return !(n.hasPrefix("utm_") || exact.contains(n))
        }
        guard kept.count != items.count else { return url }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.url ?? url
    }
}
