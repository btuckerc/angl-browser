import Foundation

/// Everything that isn't a theme token. ~/.config/angl/settings.json overrides any subset.
public struct Settings: Codable, Equatable, Sendable {
    public var search = Search()
    public var content = Content()
    public var tabs = Tabs()
    public var downloads = Downloads()
    public var privacy = Privacy()
    public var blocking = Blocking()
    public var engines = Engines()
    public var snapshots = Snapshots()
    public var developer = Developer()
    public var passwords = Passwords()
    public var twitch = Twitch()

    public init() {}

    public struct Search: Codable, Equatable, Sendable {
        /// `%s` is replaced by the percent-encoded query.
        public var engine = "https://duckduckgo.com/?q=%s"
        /// Typing "<keyword> <query>" searches there.
        public var keywords: [String: String] = [
            "d": "https://duckduckgo.com/?q=%s",
            "g": "https://www.google.com/search?q=%s",
            "w": "https://en.wikipedia.org/wiki/Special:Search?search=%s",
            "yt": "https://www.youtube.com/results?search_query=%s",
            "gh": "https://github.com/search?q=%s",
            "k": "https://kagi.com/search?q=%s",
        ]
    }

    public struct Content: Codable, Equatable, Sendable {
        public var javascript = true
        public var blockRemoteFonts = false
        public var blocker = true
        public var square = true
        /// Pages with their own dark theme always get it (the chrome is dark). Converting light-only
        /// pages costs CPU, so it is opt-in: per site, or globally with .auto / .force.
        public var dark: DarkMode = .off
        public var zoom: Double = 1
        /// Compress media audio FrankerFaceZ-style (Web Audio DynamicsCompressorNode) on Media Source sites.
        public var nightAudio = false
        /// Media never starts with sound until the user interacts with the page.
        public var blockAutoplay = true
        /// WebKit hardening: `.noJIT` runs JavaScript interpreter-only (macOS 26.4+
        /// `securityRestrictionMode = .maximizeCompatibility`); `.lockdown` is Lockdown Mode.
        public var hardening: Hardening = .off
    }

    public struct Tabs: Codable, Equatable, Sendable {
        /// Memory saver interval; zero disables idle unloading. Pins and active media are exempt.
        public var unloadAfterMinutes: Double = 30
        public var autoArchive = false
        public var archiveAfterHours: Double = 24
        public var restoreOnLaunch = true
        public var routeByURL = true
        /// Favourite bookmarks as an icon row above every Space's tree.
        public var favorites = false
        public var splitView = false
        /// ⌘W on the window's last tab (every Space empty) closes the window instead of leaving an empty tab.
        public var closeWindowWithLastTab = true
    }

    public struct Downloads: Codable, Equatable, Sendable {
        public var folder = "~/Downloads"
    }

    public struct Privacy: Codable, Equatable, Sendable {
        /// Strip utm_*, fbclid, gclid… from navigations and copied URLs.
        public var cleanURLs = true
        /// Send Safari's exact user agent (fewest broken sites, smallest fingerprint).
        public var safariUserAgent = true
        /// On quit, delete cookies and site data of every site not in `keepSignedIn` (LibreWolf style).
        public var forgetOnQuit = false
        /// Registrable domains whose site data survives `forgetOnQuit` (logins stay put).
        public var keepSignedIn: [String] = ["google.com", "youtube.com"]
    }

    public struct Blocking: Codable, Equatable, Sendable {
        public var lists: [FilterList] = FilterList.defaults
        public var updateEveryDays: Double = 7
        /// Scriptlets and advanced cosmetic rules (needed for e.g. YouTube); network rules stay on regardless.
        public var advanced = true
    }

    public struct Engines: Codable, Equatable, Sendable {
        /// Hosts that always hand off to another engine (e.g. passkey sign-ins → Safari).
        public var rules: [EngineRule] = []
    }

    public struct Snapshots: Codable, Equatable, Sendable {
        public var autoEveryMinutes: Double = 10
        public var keep = 20
    }

    public struct Developer: Codable, Equatable, Sendable {
        /// Web Inspector (Cmd-Opt-I) on every tab.
        public var inspector = true
    }

    public struct Passwords: Codable, Equatable, Sendable {
        public enum Provider: String, Codable, Sendable { case bitwarden, none }
        public var provider: Provider = .bitwarden
        /// Bitwarden server: "bitwarden.com", "bitwarden.eu" or a self-hosted https address.
        public var server = "bitwarden.com"
        /// An "Apple Passwords…" row in the picker (the system AutoFill picker in a native sheet).
        public var applePasswords = true
        /// Show matching logins as soon as a sign-in field gets focus (⌘\ always works).
        public var suggestOnFocus = true
        /// Lock the vault after this many idle minutes (0 = only on quit).
        public var lockAfterMinutes: Double = 0
        /// Copy a login's one-time code after filling its credentials.
        public var copyTOTP = true
        /// Keep the vault's user key in the login keychain, released by Touch ID, across launches.
        public var rememberUnlock = false
    }

    public struct Twitch: Codable, Equatable, Sendable {
        /// BTTV / FFZ / 7TV emotes in twitch.tv chat.
        public var emotes = true
        public var bttv = true
        public var ffz = true
        public var seventv = true
        /// false = first frame only (less CPU on busy chats).
        public var animated = true
    }

    public static func load(from url: URL) throws -> Settings {
        try JSONFile.layered(Settings(), file: url)
    }

    /// Expand a search template with a query.
    public static func searchURL(template: String, query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: q))
    }
}

public enum DarkMode: String, Codable, Sendable, CaseIterable {
    /// Leave sites that support dark mode alone; darken light-only sites.
    case auto
    /// Darken every page.
    case force
    case off
}

public enum Hardening: String, Codable, Sendable, CaseIterable {
    case off
    /// JavaScript without the JIT (interpreter only).
    case noJIT
    /// WebKit Lockdown Mode: no JIT, many web features off.
    case lockdown
}

public struct FilterList: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    public var enabled: Bool

    public init(id: String, name: String, url: String, enabled: Bool) {
        self.id = id; self.name = name; self.url = url; self.enabled = enabled
    }

    public static let defaults: [FilterList] = [
        FilterList(id: "adguard-base", name: "AdGuard Base (Safari optimized)", url: "https://filters.adtidy.org/extension/safari/filters/2_optimized.txt", enabled: true),
        FilterList(id: "adguard-tracking", name: "AdGuard Tracking Protection (Safari optimized)", url: "https://filters.adtidy.org/extension/safari/filters/3_optimized.txt", enabled: true),
        FilterList(id: "ubo-filters", name: "uBlock filters", url: "https://ublockorigin.github.io/uAssets/filters/filters.txt", enabled: false),
        FilterList(id: "annoyances-cookies", name: "AdGuard Cookie Notices (Safari optimized)", url: "https://filters.adtidy.org/extension/safari/filters/18_optimized.txt", enabled: false),
    ]
}

public struct EngineRule: Codable, Equatable, Sendable {
    public var match: URLRule
    /// An `Engine.id`.
    public var engine: String

    public init(match: URLRule, engine: String) {
        self.match = match; self.engine = engine
    }
}
