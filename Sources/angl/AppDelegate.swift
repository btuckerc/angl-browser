import AnglCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private var lockFD: Int32 = -1

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Text in pages and fields stays exactly as typed (Search.app did the same).
        let off = [
            "WebAutomaticQuoteSubstitutionEnabled", "WebAutomaticDashSubstitutionEnabled", "WebAutomaticTextReplacementEnabled",
            "WebAutomaticSpellingCorrectionEnabled", "WebContinuousSpellCheckingEnabled", "WebGrammarCheckingEnabled",
            "NSAutomaticQuoteSubstitutionEnabled", "NSAutomaticDashSubstitutionEnabled", "NSAutomaticTextReplacementEnabled",
            "NSAutomaticSpellingCorrectionEnabled", "NSAutomaticCapitalizationEnabled", "NSAutomaticPeriodSubstitutionEnabled",
        ]
        UserDefaults.standard.register(defaults: Dictionary(uniqueKeysWithValues: off.map { ($0, false) }))
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let profile = Profiles.current()
        let paths = Paths(profile: profile)
        try? paths.ensureDirectories()
        guard lockProfile(paths) else {
            // This profile is already open in another angl: bring that one forward instead.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where app != NSRunningApplication.current {
                app.activate()
            }
            NSApp.terminate(nil)
            return
        }
        let browser = Browser(profile: profile)
        Browser.shared = browser
        Commands.loadOverrides(paths)
        NSApp.mainMenu = Commands.buildMainMenu()
        browser.start()
        let restored = browser.restoreSession()
        if !pendingURLs.isEmpty {
            browser.open(urls: pendingURLs)
            pendingURLs = []
        } else if !restored {
            browser.newWindow()
        }
    }

    /// One running instance per profile: an flock on the profile's state directory.
    private func lockProfile(_ paths: Paths) -> Bool {
        let fd = open(paths.stateDir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        lockFD = fd
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let handled = urls.filter { ["http", "https", "file"].contains($0.scheme ?? "") }
        guard let b = Browser.shared else { pendingURLs += handled; return }
        b.open(urls: handled)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let b = Browser.shared { if b.windows.isEmpty { b.newWindow() } else { b.windows.last?.showWindow(nil) } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        m.addItem(ClosureMenuItem("New Window") { Browser.shared?.newWindow() })
        return m
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let b = Browser.shared else { return .terminateNow }
        b.willTerminate()
        let wipe = b.workspaces.containers.filter(\.clearOnQuit)
        let privacy = b.settings.privacy
        let forget = privacy.forgetOnQuit ? b.workspaces.containers.filter { !$0.clearOnQuit } : []
        guard !wipe.isEmpty || !forget.isEmpty else { return .terminateNow }
        Task { @MainActor in
            for c in wipe { await b.web.clearData(of: c) }
            for c in forget { await b.web.forgetSites(in: c, keeping: privacy.keepSignedIn) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
