import Foundation

/// Where angl keeps things. Config the user edits lives in ~/.config/angl (chezmoi-friendly);
/// machine state lives in ~/Library/Application Support/angl/<profile>.
public struct Paths: Sendable {
    public let profile: String
    public let configDir: URL
    public let stateDir: URL

    public init(profile: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.profile = profile
        let config = home.appendingPathComponent(".config/angl", isDirectory: true)
        configDir = profile == Paths.defaultProfile
            ? config
            : config.appendingPathComponent("profiles/\(profile)", isDirectory: true)
        stateDir = home.appendingPathComponent("Library/Application Support/angl/\(profile)", isDirectory: true)
    }

    public static let defaultProfile = "default"

    /// Profile names are path components and data-store seeds: keep them boring.
    public static func isValidProfileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 32 && name.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
    }

    public var themeFile: URL { configDir.appendingPathComponent("theme.json") }
    public var settingsFile: URL { configDir.appendingPathComponent("settings.json") }
    public var keysFile: URL { configDir.appendingPathComponent("keys.json") }
    public var cssDir: URL { configDir.appendingPathComponent("css", isDirectory: true) }

    public var sessionFile: URL { stateDir.appendingPathComponent("session.json") }
    public var workspacesFile: URL { stateDir.appendingPathComponent("workspaces.json") }
    public var sitesFile: URL { stateDir.appendingPathComponent("sites.json") }
    public var bookmarksFile: URL { stateDir.appendingPathComponent("bookmarks.json") }
    public var historyDB: URL { stateDir.appendingPathComponent("history.sqlite") }
    public var downloadsFile: URL { stateDir.appendingPathComponent("downloads.json") }
    public var snapshotsDir: URL { stateDir.appendingPathComponent("snapshots", isDirectory: true) }
    public var listsDir: URL { stateDir.appendingPathComponent("lists", isDirectory: true) }
    /// One small PNG per host, so restored (unloaded) tabs show their icon without a fetch.
    public var faviconsDir: URL { stateDir.appendingPathComponent("favicons", isDirectory: true) }

    /// All profiles that have state on disk.
    public static func existingProfiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let root = home.appendingPathComponent("Library/Application Support/angl", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter(isValidProfileName).sorted()
    }

    public func ensureDirectories() throws {
        for dir in [configDir, cssDir, stateDir, snapshotsDir, listsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
