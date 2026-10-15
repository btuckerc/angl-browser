import AnglCore
import AppKit

/// "Open in …": hands a URL to another installed browser engine. Cookies, POST bodies and the
/// container's proxy do not travel.
@MainActor
enum Handoff {
    static func appURL(for engine: Engine) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: engine.bundleID)
    }

    static var installed: [Engine] { Engine.known.filter { appURL(for: $0) != nil } }

    static func open(_ url: URL, in engine: Engine) async -> Bool {
        guard let app = appURL(for: engine), url.scheme == "http" || url.scheme == "https" else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg)
            return true
        } catch {
            return false
        }
    }
}

/// Profiles are separate app instances: `angl --profile mom` or `open -na angl --args --profile mom`.
enum Profiles {
    static func current(arguments: [String] = CommandLine.arguments) -> String {
        if let i = arguments.firstIndex(of: "--profile"), i + 1 < arguments.count,
           Paths.isValidProfileName(arguments[i + 1]) {
            return arguments[i + 1]
        }
        return Paths.defaultProfile
    }

    @MainActor
    static func launch(_ name: String) throws {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.arguments = ["--profile", name]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg)
    }
}

/// Imports into a new folder in the current workspace (bookmarks into the bookmark store).
@MainActor
enum Importing {
    static func run(_ source: String, window: BrowserWindowController?) async throws -> (Int, String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let b = Browser.shared!
        var marks: [Bookmark] = []
        var folder = ""
        switch source {
        case "safari":
            folder = "Safari"
            let plist = home.appendingPathComponent("Library/Safari/Bookmarks.plist")
            do { marks = try Importers.safariBookmarks(plist: plist) } catch {
                // Safari's folder needs Full Disk Access.
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                throw PageCommands.Failure(message: "angl needs Full Disk Access to read Safari bookmarks")
            }
        case "chrome":
            folder = "Chrome"
            marks = try Importers.chromeBookmarks(json: home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks"))
            if let h = b.history {
                let hist = (try? Importers.chromeHistory(sqlite: home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"))) ?? []
                for item in hist.prefix(20000) {
                    if let u = URL(string: item.url) { h.record(url: u, title: item.title, typed: false) }
                }
            }
        case "html":
            folder = "Imported"
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.html]
            guard await PageCommands.present(panel, window) == .OK, let url = panel.url else { return (0, "") }
            marks = Importers.htmlBookmarks(try String(contentsOf: url, encoding: .utf8))
        case "search":
            // Search.app exposes its tabs through AppleScript (Safari's terminology).
            folder = "from Search"
            let script = NSAppleScript(source: """
            set out to ""
            tell application id "com.officecommun.search"
              repeat with w in windows
                repeat with t in tabs of w
                  set out to out & (URL of t) & tab & (name of t) & linefeed
                end repeat
              end repeat
            end tell
            return out
            """)
            var err: NSDictionary?
            let text = script?.executeAndReturnError(&err).stringValue ?? ""
            if err != nil { throw PageCommands.Failure(message: "Search.app didn't answer (is it running? allow Automation)") }
            let tabs = text.split(separator: "\n").compactMap { line -> (URL, String)? in
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard let u = parts.first.flatMap(URL.init(string:)) else { return nil }
                return (u, parts.count > 1 ? parts[1] : "")
            }
            guard let w = window ?? b.frontWindow else { return (0, folder) }
            w.openFolder(named: folder, tabs: tabs)
            return (tabs.count, folder)
        default:
            throw PageCommands.Failure(message: "unknown source \(source)")
        }
        var store = b.bookmarks
        let count = marks.reduce(0) { $0 + countLeaves($1) }
        store.root.append(Bookmark(title: folder, children: marks))
        b.setBookmarks(store)
        return (count, folder)
    }

    private static func countLeaves(_ b: Bookmark) -> Int {
        b.url != nil ? 1 : (b.children ?? []).map(countLeaves).reduce(0, +)
    }
}
