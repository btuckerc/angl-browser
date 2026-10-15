import Foundation

/// Per-site overrides (sites.json). Keys are hosts; lookups walk up parent domains, so a rule
/// for example.com covers www.example.com unless that host has its own entry.
public struct SiteOverrides: Codable, Equatable, Sendable {
    public var javascript: Bool?
    public var blocker: Bool?
    public var blockRemoteFonts: Bool?
    public var square: Bool?
    public var dark: DarkMode?
    public var zoom: Double?
    /// Volume attenuation in dB, -30…0 (angl never amplifies); nil = 0 dB.
    public var volumeDB: Double?
    /// Camera / microphone decisions: true = allow, false = deny.
    public var camera: Bool?
    public var microphone: Bool?
    public var hardening: Hardening?

    public init() {}

    public var isEmpty: Bool { self == SiteOverrides() }
}

/// The resolved settings for one page load.
public struct SitePolicy: Equatable, Sendable {
    public var javascript: Bool
    public var blocker: Bool
    public var blockRemoteFonts: Bool
    public var square: Bool
    public var dark: DarkMode
    public var zoom: Double
    public var volumeDB: Double
    public var camera: Bool?
    public var microphone: Bool?
    public var hardening: Hardening
}

public struct SiteStore: Codable, Equatable, Sendable {
    public var sites: [String: SiteOverrides] = [:]

    public init() {}

    public static func load(from url: URL) throws -> SiteStore {
        try JSONFile.read(SiteStore.self, from: url) ?? SiteStore()
    }

    /// Lowercased host without a leading "www.".
    public static func key(for url: URL) -> String? {
        guard var h = url.host()?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// Every override field resolves from the most specific host that sets it.
    public func policy(for url: URL, defaults: Settings.Content) -> SitePolicy {
        var chain: [SiteOverrides] = []
        if var host = SiteStore.key(for: url) {
            while true {
                if let o = sites[host] { chain.append(o) }
                guard let dot = host.firstIndex(of: ".") else { break }
                host = String(host[host.index(after: dot)...])
                if !host.contains(".") { break } // stop before bare TLD
            }
        }
        func pick<T>(_ kp: KeyPath<SiteOverrides, T?>) -> T? { chain.lazy.compactMap { $0[keyPath: kp] }.first }
        return SitePolicy(
            javascript: pick(\.javascript) ?? defaults.javascript,
            blocker: pick(\.blocker) ?? defaults.blocker,
            blockRemoteFonts: pick(\.blockRemoteFonts) ?? defaults.blockRemoteFonts,
            square: pick(\.square) ?? defaults.square,
            dark: pick(\.dark) ?? defaults.dark,
            zoom: pick(\.zoom) ?? defaults.zoom,
            volumeDB: pick(\.volumeDB) ?? 0,
            camera: pick(\.camera),
            microphone: pick(\.microphone),
            hardening: pick(\.hardening) ?? defaults.hardening
        )
    }

    /// Edit the overrides for exactly this site's key; empty entries are dropped.
    public mutating func update(_ url: URL, _ change: (inout SiteOverrides) -> Void) {
        guard let key = SiteStore.key(for: url) else { return }
        var o = sites[key] ?? SiteOverrides()
        change(&o)
        sites[key] = o.isEmpty ? nil : o
    }
}
