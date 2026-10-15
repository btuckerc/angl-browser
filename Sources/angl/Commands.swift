import AnglCore
import AppKit

/// Every action angl offers: menu items, key chords (rebindable in keys.json) and palette entries
/// share this one table.
@MainActor
struct Command {
    enum Menu: String { case app, file, edit, view, history, tabs, workspaces, window, none }

    let id: String
    let title: String
    let menu: Menu
    let defaultChord: String
    /// nil window = no browser window open; commands that need one are disabled.
    let needsWindow: Bool
    let run: @MainActor (BrowserWindowController?) -> Void

    init(_ id: String, _ title: String, _ menu: Menu, _ chord: String = "", needsWindow: Bool = true,
         _ run: @escaping @MainActor (BrowserWindowController?) -> Void) {
        self.id = id; self.title = title; self.menu = menu; defaultChord = chord
        self.needsWindow = needsWindow; self.run = run
    }

    var chord: String { Commands.overrides[id] ?? defaultChord }
    var chordLabel: String { Chord(chord)?.label ?? "" }
}

/// "cmd+shift+t", "ctrl+tab", "cmd+opt+up". Parsed into an NSMenuItem key equivalent.
struct Chord {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }
        var m: NSEvent.ModifierFlags = []
        for p in parts.dropLast() {
            switch p {
            case "cmd", "command": m.insert(.command)
            case "shift": m.insert(.shift)
            case "opt", "alt", "option": m.insert(.option)
            case "ctrl", "control": m.insert(.control)
            default: return nil
            }
        }
        let named: [String: Int] = [
            "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey, "left": NSLeftArrowFunctionKey,
            "right": NSRightArrowFunctionKey, "tab": 0x09, "return": 0x0D, "esc": 0x1B, "delete": 0x08,
            "space": 0x20, "plus": 0x2B, "minus": 0x2D,
        ]
        if let code = named[last], let scalar = UnicodeScalar(code) {
            key = String(Character(scalar))
        } else if last.count == 1 {
            key = last
            // Shifted punctuation: AppKit matches the shifted character.
            let shifted: [String: String] = ["[": "{", "]": "}", "=": "+", "/": "?", "\\": "|", ";": ":", "'": "\"",
                                             ",": "<", ".": ">", "`": "~", "-": "_"]
            if m.contains(.shift), let s = shifted[last] { key = s }
        } else {
            return nil
        }
        modifiers = m
    }

    var label: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let names: [Int: String] = [NSUpArrowFunctionKey: "↑", NSDownArrowFunctionKey: "↓", NSLeftArrowFunctionKey: "←",
                                    NSRightArrowFunctionKey: "→", 0x09: "⇥", 0x0D: "↩", 0x1B: "⎋", 0x08: "⌫", 0x20: "Space"]
        if let v = key.unicodeScalars.first.map({ Int($0.value) }), let n = names[v] { return s + n }
        return s + key.uppercased()
    }
}

@MainActor
enum Commands {
    /// keys.json: {"tab.new": "cmd+t", "tab.mute": ""}. Empty string unbinds.
    static var overrides: [String: String] = [:]

    static func loadOverrides(_ paths: Paths) {
        overrides = (try? JSONFile.read([String: String].self, from: paths.keysFile)) ?? [:]
    }

    static func command(_ id: String) -> Command? { all.first { $0.id == id } }

    static let all: [Command] = {
        var c: [Command] = [
            Command("app.about", "About angl", .app, needsWindow: false) { w in open(w, InternalPages.url("about")) },
            Command("app.settings", "Settings…", .app, "cmd+,", needsWindow: false) { w in open(w, InternalPages.url("settings")) },

            Command("tab.new", "New Tab", .file, "cmd+t", needsWindow: false) { w in
                (w ?? Browser.shared.newWindow()).newTab()
            },
            Command("window.new", "New Window", .file, "cmd+n", needsWindow: false) { _ in Browser.shared.newWindow() },
            Command("tab.reopen", "Reopen Closed Tab", .file, "cmd+shift+t") { $0?.reopenClosed() },
            Command("nav.location", "Open Location…", .file, "cmd+l") { $0?.focusURLField() },
            Command("palette", "Command Palette…", .file, "cmd+k") { $0?.openPalette() },
            Command("tab.close", "Close Tab", .file, "cmd+w") { $0?.closeActive(subtree: false) },
            Command("tab.closeSubtree", "Close Tab and Children", .file, "cmd+opt+w") { $0?.closeActive(subtree: true) },
            Command("window.close", "Close Window", .file, "cmd+shift+w") { $0?.window?.performClose(nil) },
            Command("snapshot.take", "Take Snapshot", .file, "cmd+shift+s") { w in
                if Browser.shared.takeSnapshot(auto: false) != nil {
                    Browser.shared.post(.anglSnapshots)
                    w?.toast("snapshot saved", color: Browser.shared.style.ok)
                }
            },
            Command("bookmark.add", "Bookmark Page", .file, "cmd+d") { $0?.bookmarkActive() },
            Command("import.safari", "Import Safari Bookmarks", .file, needsWindow: false) { w in runImport("safari", w) },
            Command("import.chrome", "Import Chrome Bookmarks and History", .file, needsWindow: false) { w in runImport("chrome", w) },
            Command("import.html", "Import Bookmarks File…", .file, needsWindow: false) { w in runImport("html", w) },
            Command("import.search", "Import Tabs from Search", .file, needsWindow: false) { w in runImport("search", w) },

            Command("find", "Find…", .edit, "cmd+f") { $0?.showFind() },
            Command("find.next", "Find Next", .edit, "cmd+g") { $0?.findNext(backwards: false) },
            Command("find.prev", "Find Previous", .edit, "cmd+shift+g") { $0?.findNext(backwards: true) },
            Command("nav.copyURL", "Copy Clean URL", .edit, "cmd+shift+c") { $0?.copyCleanURL() },

            Command("view.sidebar", "Toggle Sidebar", .view, "cmd+shift+l") { $0?.toggleSidebar() },
            Command("view.focus", "Focus Mode", .view, "cmd+shift+\\") { $0?.toggleFocusMode() },
            Command("passwords.fill", "Fill Login", .edit, "cmd+\\") { w in if let tab = w?.active { Passwords.shared.fillFocused(in: tab) } },
            Command("passwords.login", "Log In to Bitwarden…", .edit) { w in
                if let window = w?.window { Task { await Passwords.shared.logIn(in: window) } }
            },
            Command("passwords.lock", "Lock Bitwarden", .edit) { _ in Passwords.shared.lock(revoke: true) },
            Command("passwords.logout", "Log Out of Bitwarden", .edit) { _ in Passwords.shared.logOut() },
            Command("nav.reload", "Reload", .view, "cmd+r") { $0?.active?.reload(fromOrigin: false) },
            Command("nav.reloadOrigin", "Reload from Origin", .view, "cmd+shift+r") { $0?.active?.reload(fromOrigin: true) },
            Command("nav.stop", "Stop", .view, "cmd+.") { $0?.active?.webView?.stopLoading() },
            Command("view.zoomIn", "Zoom In", .view, "cmd+=") { $0?.zoom(by: 0.1) },
            Command("view.zoomOut", "Zoom Out", .view, "cmd+-") { $0?.zoom(by: -0.1) },
            Command("view.zoomReset", "Actual Size", .view, "cmd+0") { $0?.zoom(by: nil) },
            Command("site.panel", "Site Settings…", .view, "cmd+shift+i") { $0?.showSitePanel() },
            Command("site.js", "Toggle JavaScript for Site", .view, "cmd+shift+j") { w in
                w?.changeSite { p, o in o.javascript = !p.javascript }
            },
            Command("site.dark", "Cycle Dark Mode for Site", .view, "cmd+shift+d") { w in
                w?.changeSite { p, o in o.dark = p.dark == .auto ? .force : p.dark == .force ? .off : .auto }
            },
            Command("site.square", "Toggle Square Corners for Site", .view, "cmd+shift+u") { w in
                w?.changeSite { p, o in o.square = !p.square }
            },
            Command("site.blocker", "Toggle Blocker for Site", .view) { w in w?.changeSite { p, o in o.blocker = !p.blocker } },
            Command("site.fonts", "Toggle Remote Fonts for Site", .view) { w in
                w?.changeSite { p, o in o.blockRemoteFonts = !p.blockRemoteFonts }
            },
            Command("dev.inspector", "Web Inspector", .view, "cmd+opt+i") { $0?.active?.showInspector() },

            Command("nav.back", "Back", .history, "cmd+[") { $0?.active?.webView?.goBack() },
            Command("nav.forward", "Forward", .history, "cmd+]") { $0?.active?.webView?.goForward() },
            Command("page.history", "Show History", .history, "cmd+y", needsWindow: false) { w in open(w, InternalPages.url("history")) },
            Command("page.downloads", "Show Downloads", .history, "cmd+opt+l", needsWindow: false) { w in
                open(w, InternalPages.url("downloads"))
            },
            Command("page.snapshots", "Show Snapshots", .history, needsWindow: false) { w in open(w, InternalPages.url("snapshots")) },
            Command("page.sites", "Show Site Settings", .history, needsWindow: false) { w in open(w, InternalPages.url("sites")) },

            Command("tab.next", "Next Tab", .tabs, "ctrl+tab") { $0?.selectTab(offset: 1) },
            Command("tab.prev", "Previous Tab", .tabs, "ctrl+shift+tab") { $0?.selectTab(offset: -1) },
            Command("tab.nextAlt", "Next Tab", .tabs, "cmd+shift+]") { $0?.selectTab(offset: 1) },
            Command("tab.prevAlt", "Previous Tab", .tabs, "cmd+shift+[") { $0?.selectTab(offset: -1) },
            Command("tab.parent", "Parent Tab", .tabs, "cmd+opt+up") { $0?.selectParent() },
            Command("tab.child", "First Child Tab", .tabs, "cmd+opt+down") { $0?.selectFirstChild() },
            Command("tab.pin", "Pin / Unpin Tab", .tabs, "cmd+shift+p") { w in w?.active.map { w?.togglePin($0) } },
            Command("tab.mute", "Mute / Unmute Tab", .tabs, "cmd+shift+m") { w in w?.active?.toggleMute() },
            Command("tab.duplicate", "Duplicate Tab", .tabs) { w in w?.active.map { w?.duplicate($0) } },
            Command("split.toggle", "Split View / Exit Split", .tabs, "cmd+opt+\\") { $0?.toggleSplitChooser() },
            Command("split.left", "Focus Left Pane", .tabs, "cmd+opt+left") { $0?.focusSplitPane(left: true) },
            Command("split.right", "Focus Right Pane", .tabs, "cmd+opt+right") { $0?.focusSplitPane(left: false) },
            Command("tab.unload", "Unload Other Tabs", .tabs) { $0?.unloadOthers() },
            Command("sidebar.focus", "Focus Sidebar", .tabs, "cmd+shift+e") { $0?.focusSidebar() },
            Command("handoff.last", "Open Page in Other Browser", .tabs, "cmd+shift+o") { $0?.handoffActive(engine: nil) },

            Command("ws.next", "Next Space", .workspaces, "ctrl+shift+right") { $0?.cycleWorkspace(by: 1) },
            Command("ws.prev", "Previous Space", .workspaces, "ctrl+shift+left") { $0?.cycleWorkspace(by: -1) },
            Command("ws.edit", "Edit Spaces…", .workspaces, needsWindow: false) { w in open(w, InternalPages.url("spaces")) },

            Command("blocker.update", "Update Block Lists", .none, needsWindow: false) { w in
                Browser.shared.web.blocker.update(settings: Browser.shared.settings)
                w?.toast("updating block lists…", color: Browser.shared.style.secondary)
            },
            Command("app.defaultBrowser", "Make angl the Default Browser", .none, needsWindow: false) { w in
                Task { @MainActor in
                    do {
                        for scheme in ["http", "https"] {
                            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
                        }
                        w?.toast("angl is the default browser", color: Browser.shared.style.ok)
                    } catch {
                        w?.toast(error.localizedDescription, color: Browser.shared.style.danger)
                    }
                }
            },
        ]
        for i in 1...9 {
            c.append(Command("tab.\(i)", i == 9 ? "Last Tab" : "Tab \(i)", .tabs, "cmd+\(i)") { $0?.selectTab(index: i == 9 ? -1 : i - 1) })
        }
        for i in 1...9 {
            c.append(Command("ws.\(i)", "Space \(i)", .workspaces, "ctrl+\(i)") { $0?.switchWorkspace(index: i - 1) })
        }
        return c
    }()

    private static func open(_ w: BrowserWindowController?, _ url: URL) {
        (w ?? Browser.shared.frontWindow ?? Browser.shared.newWindow()).openInternal(url)
    }

    private static func runImport(_ source: String, _ w: BrowserWindowController?) {
        Task { @MainActor in
            do {
                let (n, folder) = try await Importing.run(source, window: w)
                w?.toast("imported \(n) into \(folder)", color: Browser.shared.style.ok)
            } catch {
                w?.toast((error as? PageCommands.Failure)?.message ?? error.localizedDescription, color: Browser.shared.style.danger)
            }
        }
    }

    // MARK: Palette verbs

    /// A palette row: title, detail, and what Return does.
    struct Entry {
        var title: String
        var detail: String
        var hint: String
        var run: @MainActor (BrowserWindowController?) -> Void
    }

    /// Commands matching `text` plus argument verbs ("js off", "profile mom", "dark force").
    static func palette(_ text: String, window: BrowserWindowController?) -> [Entry] {
        let q = text.lowercased()
        let words = q.split(separator: " ").map(String.init)
        var out: [Entry] = []
        let verb = words.first ?? ""
        let arg = words.dropFirst().joined(separator: " ")
        func onOff(_ name: String, _ title: String, _ change: @escaping (Bool, inout SiteOverrides) -> Void) {
            guard name.hasPrefix(verb) || verb.hasPrefix(name) else { return }
            for v in ["on", "off"] where arg.isEmpty || v.hasPrefix(arg) {
                out.append(Entry(title: "\(title) \(v)", detail: "this site", hint: "") { w in
                    w?.changeSite { _, o in change(v == "on", &o) }
                })
            }
        }
        onOff("js", "JavaScript") { on, o in o.javascript = on }
        onOff("square", "Square corners") { on, o in o.square = on }
        onOff("blocker", "Blocker") { on, o in o.blocker = on }
        onOff("fonts", "Remote fonts") { on, o in o.blockRemoteFonts = !on }
        if "dark".hasPrefix(verb) || verb == "dark" {
            for m in DarkMode.allCases where arg.isEmpty || m.rawValue.hasPrefix(arg) {
                out.append(Entry(title: "Dark \(m.rawValue)", detail: "this site", hint: "") { w in
                    w?.changeSite { _, o in o.dark = m }
                })
            }
        }
        if "profile".hasPrefix(verb), !verb.isEmpty {
            var names = Paths.existingProfiles()
            if !arg.isEmpty, Paths.isValidProfileName(arg), !names.contains(arg) { names.insert(arg, at: 0) }
            for n in names where arg.isEmpty || n.hasPrefix(arg) {
                out.append(Entry(title: "Profile \(n)", detail: n == Browser.shared.paths.profile ? "current" : "open in new instance", hint: "") { _ in
                    try? Paths(profile: n).ensureDirectories()
                    try? Profiles.launch(n)
                })
            }
        }
        if "open".hasPrefix(verb), !verb.isEmpty {
            for e in Handoff.installed where arg.isEmpty || e.name.lowercased().hasPrefix(arg) {
                out.append(Entry(title: "Open in \(e.name)", detail: "hand off this page", hint: "") { w in w?.handoffActive(engine: e) })
            }
        }
        if "container".hasPrefix(verb), !verb.isEmpty {
            for c in Browser.shared.workspaces.containers where arg.isEmpty || c.name.lowercased().hasPrefix(arg) {
                out.append(Entry(title: "Move tab to container \(c.name)", detail: c.proxy?.label ?? "", hint: "") { w in
                    w?.active.map { w?.move($0, toContainer: c.id) }
                })
            }
        }
        if "space".hasPrefix(verb), !verb.isEmpty {
            for (i, ws) in Browser.shared.workspaces.workspaces.enumerated() where arg.isEmpty || ws.name.lowercased().hasPrefix(arg) {
                out.append(Entry(title: "Space \(ws.name)", detail: "", hint: i < 9 ? "⌃\(i + 1)" : "") { w in
                    w?.switchWorkspace(index: i)
                })
            }
        }
        for c in all where c.menu != .none || true {
            let hay = (c.title + " " + c.id.replacingOccurrences(of: ".", with: " ")).lowercased()
            guard q.isEmpty || words.allSatisfy({ hay.contains($0) }) else { continue }
            if c.needsWindow && window == nil { continue }
            out.append(Entry(title: c.title, detail: "", hint: c.chordLabel) { w in c.run(w) })
        }
        return out
    }

    // MARK: Menus

    static func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return m
        }
        func add(_ menu: Command.Menu, to m: NSMenu) {
            for c in all where c.menu == menu { m.addItem(item(c)) }
        }

        let app = submenu("angl")
        add(.app, to: app)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide angl", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit angl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu("File")
        add(.file, to: file)

        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteMatch = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        add(.edit, to: edit)

        let view = submenu("View")
        add(.view, to: view)
        view.addItem(.separator())
        let full = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]

        add(.history, to: submenu("History"))
        add(.tabs, to: submenu("Tabs"))
        add(.workspaces, to: submenu("Spaces"))

        let window = submenu("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        return main
    }

    private static func item(_ c: Command) -> NSMenuItem {
        let item = NSMenuItem(title: c.title, action: #selector(CommandRouter.runCommand(_:)), keyEquivalent: "")
        item.target = CommandRouter.shared
        item.representedObject = c.id
        if let chord = Chord(c.chord) {
            item.keyEquivalent = chord.key
            item.keyEquivalentModifierMask = chord.modifiers
        }
        return item
    }
}

/// Menu target: runs commands against the front browser window.
@MainActor
final class CommandRouter: NSObject, NSMenuItemValidation {
    static let shared = CommandRouter()

    @objc func runCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let c = Commands.command(id) else { return }
        c.run(Browser.shared.frontWindow)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.representedObject as? String, let c = Commands.command(id) else { return true }
        let w = Browser.shared?.frontWindow
        if c.needsWindow && w == nil { return false }
        switch id {
        case "nav.back": return w?.active?.webView?.canGoBack ?? false
        case "nav.forward": return w?.active?.webView?.canGoForward ?? false
        case "find.next", "find.prev": return w?.findVisible ?? false
        case "tab.reopen": return w?.canReopen ?? false
        case "split.toggle": return Browser.shared?.settings.tabs.splitView ?? false
        case "split.left", "split.right": return w?.isSplit ?? false
        default: return true
        }
    }
}
