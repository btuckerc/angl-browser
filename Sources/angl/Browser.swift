import AnglCore
import AppKit
import WebKit

extension Notification.Name {
    static let anglTheme = Notification.Name("angl.theme")
    static let anglSettings = Notification.Name("angl.settings")
    static let anglWorkspaces = Notification.Name("angl.workspaces")
    static let anglSites = Notification.Name("angl.sites")
    static let anglDownloads = Notification.Name("angl.downloads")
    static let anglBlocking = Notification.Name("angl.blocking")
    static let anglSnapshots = Notification.Name("angl.snapshots")
    static let anglUserCSS = Notification.Name("angl.usercss")
    static let anglBookmarks = Notification.Name("angl.bookmarks")
    static let anglPower = Notification.Name("angl.power")
}

/// Process-wide state for one profile: config, stores, WebKit environment, windows.
@MainActor
final class Browser {
    static var shared: Browser!

    let paths: Paths
    private(set) var settings: Settings
    private(set) var theme: Theme
    private(set) var style: Style
    private(set) var workspaces: WorkspaceConfig
    private(set) var sites: SiteStore
    private(set) var bookmarks: BookmarkStore
    let history: HistoryStore?
    let snapshots: SnapshotStore
    let web: WebEnvironment
    let downloads: Downloads
    private(set) var problems: [String] = []
    private(set) var windows: [BrowserWindowController] = []
    private var watcher: ConfigWatcher?
    private var appearanceObservation: NSKeyValueObservation?
    private var applyingAppearance = false
    private var housekeeping: Timer?
    private var pendingSave: Timer?
    private var lastSnapshotSession: SessionState?

    init(profile: String) {
        let paths = Paths(profile: profile)
        self.paths = paths
        try? paths.ensureDirectories()
        var problems: [String] = []
        func load<T>(_ name: String, _ fallback: T, _ body: () throws -> T) -> T {
            do { return try body() } catch {
                problems.append("\(name): \(error.localizedDescription)")
                return fallback
            }
        }
        settings = load("settings.json", Settings()) { try Settings.load(from: paths.settingsFile) }
        theme = load("theme.json", Theme()) { try Theme.load(from: paths.themeFile) }
        style = Browser.style(for: theme)
        var ws = load("workspaces.json", WorkspaceConfig.initial()) {
            try JSONFile.read(WorkspaceConfig.self, from: paths.workspacesFile) ?? WorkspaceConfig.initial()
        }
        ws.repair(theme: theme)
        workspaces = ws
        sites = load("sites.json", SiteStore()) { try SiteStore.load(from: paths.sitesFile) }
        bookmarks = load("bookmarks.json", BookmarkStore(root: [])) { try BookmarkStore.load(from: paths.bookmarksFile) }
        history = load("history", nil) { try HistoryStore(url: paths.historyDB) }
        snapshots = SnapshotStore(dir: paths.snapshotsDir)
        web = WebEnvironment(paths: paths)
        downloads = Downloads(paths: paths)
        self.problems = problems
        try? JSONFile.write(workspaces, to: paths.workspacesFile)
    }

    func start() {
        applyAppearance()
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Browser.shared.restyle() }
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated { Browser.shared.effectiveAppearanceChanged() }
        }
        Passwords.shared.start()
        web.start(settings: settings)
        watcher = ConfigWatcher(dirs: [paths.configDir, paths.cssDir]) { [weak self] in self?.reloadConfig() }
        // Minute-granular housekeeping; the tolerance lets macOS coalesce the wakeup with others.
        let tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { Browser.shared.minuteTick() }
        }
        tick.tolerance = 10
        housekeeping = tick
    }

    // MARK: Windows

    func register(_ w: BrowserWindowController) { windows.append(w); markSessionDirty() }
    func unregister(_ w: BrowserWindowController) {
        windows.removeAll { $0 === w }
        markSessionDirty()
    }

    var frontWindow: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? windows.last
    }

    @discardableResult
    func newWindow(saved: SavedWindow? = nil, open url: URL? = nil) -> BrowserWindowController {
        let w = BrowserWindowController(browser: self, saved: saved)
        register(w)
        w.showWindow(nil)
        if let url { w.openTab(url, activate: true) }
        else if saved == nil {
            if w.paletteMode { w.openAddressPalette(prefill: nil, newTab: true) }
            else { w.focusURLField() }
        }
        return w
    }

    /// Open URLs handed to us by the system (default browser, `open -a angl URL`).
    func open(urls: [URL]) {
        let w = frontWindow ?? newWindow()
        for u in urls { w.openTab(u, activate: true) }
        w.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Session

    /// The first change schedules one save 5 s later; changes in between ride along, so sustained
    /// activity can't postpone it and a clean session never wakes the app.
    func markSessionDirty() {
        guard pendingSave == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated { Browser.shared.saveSession() }
        }
        t.tolerance = 1
        pendingSave = t
    }

    var sessionState: SessionState { SessionState(windows: windows.map { $0.saved() }) }

    func saveSession() {
        pendingSave?.invalidate()
        pendingSave = nil
        try? JSONFile.write(sessionState, to: paths.sessionFile)
    }

    func restoreSession() -> Bool {
        guard settings.tabs.restoreOnLaunch,
              let s = try? JSONFile.read(SessionState.self, from: paths.sessionFile),
              !s.windows.isEmpty else { return false }
        for w in s.windows { newWindow(saved: w) }
        return true
    }

    func takeSnapshot(auto: Bool) -> SnapshotInfo? {
        let session = sessionState
        if auto, session == lastSnapshotSession { return nil }
        lastSnapshotSession = session
        let info = try? snapshots.save(Snapshot(date: Date(), auto: auto, workspaces: workspaces, session: session))
        snapshots.prune(keepAuto: settings.snapshots.keep)
        return info
    }

    /// Opening a snapshot adds its windows; it never replaces what's open. Missing workspaces/containers
    /// are added to the profile so the restored tabs keep their cookie jars.
    func openSnapshot(_ snap: Snapshot) {
        var cfg = workspaces
        for c in snap.workspaces.containers where cfg.container(c.id) == nil { cfg.containers.append(c) }
        for w in snap.workspaces.workspaces where cfg.workspace(w.id) == nil { cfg.workspaces.append(w) }
        if cfg != workspaces { setWorkspaces(cfg) }
        for w in snap.session.windows { newWindow(saved: w) }
    }

    private var lastAutoSnapshot = Date()

    private func minuteTick() {
        let now = Date()
        let unloadAfter = settings.tabs.unloadAfterMinutes
        if unloadAfter > 0 {
            let cutoff = now.addingTimeInterval(-unloadAfter * 60)
            for w in windows { w.unloadIdleTabs(before: cutoff) }
        }
        if settings.tabs.autoArchive {
            let cutoff = now.addingTimeInterval(-settings.tabs.archiveAfterHours * 3_600)
            for w in windows { w.archiveIdleTabs(before: cutoff) }
        }
        if settings.snapshots.autoEveryMinutes > 0,
           Date().timeIntervalSince(lastAutoSnapshot) >= settings.snapshots.autoEveryMinutes * 60 {
            lastAutoSnapshot = Date()
            _ = takeSnapshot(auto: true)
        }
        web.blocker.updateIfStale(settings: settings)
    }

    func willTerminate() {
        saveSession()
        history?.flush()
        _ = takeSnapshot(auto: true)
    }

    // MARK: Config

    private func reloadConfig() {
        var problems: [String] = []
        do {
            let t = try Theme.load(from: paths.themeFile)
            if t != theme { theme = t; restyle() }
        } catch { problems.append("theme.json: \(error.localizedDescription)") }
        do {
            let s = try Settings.load(from: paths.settingsFile)
            if s != settings { settings = s; post(.anglSettings) }
        } catch { problems.append("settings.json: \(error.localizedDescription)") }
        self.problems = problems
        if web.reloadUserCSS() { post(.anglUserCSS) }
        let keys = Commands.overrides
        Commands.loadOverrides(paths)
        if keys != Commands.overrides { NSApp.mainMenu = Commands.buildMainMenu() }
        if !problems.isEmpty { frontWindow?.toast(problems.joined(separator: " · "), color: { $0.warn }) }
    }

    /// The user's theme as drawn: in the effective appearance (`system` follows macOS), with stronger
    /// text and hairlines while macOS Increase Contrast is on.
    private static func style(for t: Theme) -> Style {
        let dark = switch t.appearance {
        case .dark: true
        case .light: false
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        let drawn = t.resolved(dark: dark)
        return Style(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? drawn.increasedContrast : drawn)
    }

    private func restyle() {
        applyAppearance() // first: `system` reads the app's effective appearance
        style = Browser.style(for: theme)
        post(.anglTheme)
    }

    /// macOS switched light/dark: only a `system` theme follows, and only when what it draws changes.
    /// Ignored while angl sets `NSApp.appearance` itself: that fires this observer synchronously, before
    /// `restyle` has stored the new style, and restyling from here would recurse.
    private func effectiveAppearanceChanged() {
        guard theme.appearance == .system, !applyingAppearance else { return }
        let next = Browser.style(for: theme)
        guard next.theme.appearance != style.theme.appearance else { return }
        style = next
        post(.anglTheme)
    }

    private func applyAppearance() {
        applyingAppearance = true
        defer { applyingAppearance = false }
        switch theme.appearance {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }

    func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    /// Write one settings value (dot path) into the user's partial settings.json.
    func setSetting(path: String, value: Any?) throws {
        let s = try writeLayered(file: paths.settingsFile, path: path, value: value) { try JSONFile.layered(Settings(), user: $0, atomic: Settings.atomicPaths) }
        if s != settings { settings = s; post(.anglSettings) }
    }

    /// Write one theme token (dot path) into the user's partial theme.json.
    func setTheme(path: String, value: Any?) throws {
        let t = try writeLayered(file: paths.themeFile, path: path, value: value, decode: Theme.layered(user:))
        if t != theme { theme = t; restyle() }
    }

    /// Set `path` in a partial user JSON file, validating the decoded result (`decode` layers the
    /// user object over the defaults) before writing so a bad value never lands on disk. A file that
    /// exists but can't be read as a JSON object is left alone: rewriting it would drop every other override.
    private func writeLayered<T>(file: URL, path: String, value: Any?, decode: (Any) throws -> T) throws -> T {
        var user: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try Data(contentsOf: file)
            if !existing.isEmpty {
                guard let object = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                    throw PageCommands.Failure(message: "\(file.lastPathComponent) isn't valid JSON; fix it, then try again")
                }
                user = object
            }
        }
        user = setPath(user, path.split(separator: ".").map(String.init), value)
        let data = try JSONSerialization.data(withJSONObject: user, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let decoded = try decode(user)
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return decoded
    }

    private func setPath(_ obj: [String: Any], _ keys: [String], _ value: Any?) -> [String: Any] {
        guard let k = keys.first else { return obj }
        var o = obj
        if keys.count == 1 {
            o[k] = value
        } else {
            let child = setPath(o[k] as? [String: Any] ?? [:], Array(keys.dropFirst()), value)
            o[k] = child.isEmpty ? nil : child
        }
        return o
    }

    func setWorkspaces(_ cfg: WorkspaceConfig) {
        var c = cfg
        c.repair(theme: theme)
        let proxiesChanged = c.containers.map(\.proxy) != workspaces.containers.map(\.proxy)
        let deleted = workspaces.containers.filter { c.container($0.id) == nil }.map(\.id)
        workspaces = c
        // Erase deleted containers' data only once the deletion is on disk; otherwise a restart
        // would bring the containers back empty.
        let saved = (try? JSONFile.write(c, to: paths.workspacesFile)) != nil
        if proxiesChanged { web.applyProxies(c) }
        post(.anglWorkspaces)  // windows move their tabs off deleted containers first
        if saved { for id in deleted { Task { await web.removeStore(of: id) } } }
        markSessionDirty()
    }

    func updateSite(_ url: URL, _ change: (inout SiteOverrides) -> Void) {
        sites.update(url, change)
        try? JSONFile.write(sites, to: paths.sitesFile)
        post(.anglSites)
    }

    func setSites(_ store: SiteStore) {
        sites = store
        try? JSONFile.write(sites, to: paths.sitesFile)
        post(.anglSites)
    }

    func policy(for url: URL?) -> SitePolicy {
        guard let url, url.scheme == "http" || url.scheme == "https" else {
            // Internal and local pages: JS on, no content tweaks.
            var p = SiteStore().policy(for: URL(string: "about:blank")!, defaults: settings.content)
            p.javascript = true; p.blocker = false; p.blockRemoteFonts = false; p.square = false; p.dark = .off
            return p
        }
        return sites.policy(for: url, defaults: settings.content)
    }

    func setBookmarks(_ b: BookmarkStore) {
        bookmarks = b
        try? b.save(to: paths.bookmarksFile)
        post(.anglBookmarks)
    }

    func container(for tab: TabNode, in workspace: Workspace) -> Container {
        workspaces.container(tab.containerID ?? workspace.containerID) ?? workspaces.containers[0]
    }
}
