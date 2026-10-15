import Foundation

/// A URL pattern. Used by workspace rules ("anything with .i2p opens in the I2P workspace")
/// and engine rules ("*.bank.com opens in Safari").
public struct URLRule: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Host contains the value (case-insensitive), e.g. ".i2p". Matches the parsed host only,
        /// so query strings and paths can't trigger it.
        case contains
        /// Host equals the value or is a subdomain of it.
        case host
        /// URL string starts with the value.
        case prefix
        /// URL string matches the regular expression.
        case regex
    }

    public var kind: Kind
    public var value: String

    public init(_ kind: Kind, _ value: String) {
        self.kind = kind; self.value = value
    }

    public func matches(_ url: URL) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return false }
        switch kind {
        case .contains:
            return url.host()?.lowercased().contains(v.lowercased()) ?? false
        case .host:
            guard let host = url.host()?.lowercased() else { return false }
            let h = v.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "*."))
            return host == h || host.hasSuffix("." + h)
        case .prefix:
            return url.absoluteString.lowercased().hasPrefix(v.lowercased())
        case .regex:
            return url.absoluteString.range(of: v, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Short human form for settings and the site panel.
    public var label: String {
        switch kind {
        case .contains: "host contains \(value)"
        case .host: "host \(value)"
        case .prefix: "starts with \(value)"
        case .regex: "/\(value)/"
        }
    }
}
