import AnglCore
import AppKit
import WebKit

/// Implements the internal-page bridge: `angl.call(cmd, args)` from Resources/web/*.js.
@MainActor
enum PageCommands {
    struct Failure: Error { let message: String }

    static func run(_ cmd: String, args: [String: Any], window: BrowserWindowController?) async throws -> Any {
        let b = Browser.shared!
        switch cmd {
        case "settings.get":
            return [
                "settings": try json(b.settings),
                "defaults": try json(Settings()),
                "files": ["settings": b.paths.settingsFile.path, "theme": b.paths.themeFile.path,
                          "keys": b.paths.keysFile.path, "css": b.paths.cssDir.path],
            ]
        case "settings.set":
            let path = try string(args, "path")
            try b.setSetting(path: path, value: args["value"] is NSNull ? nil : args["value"])
            return ["settings": try json(b.settings)]
        case "settings.reset":
            try b.setSetting(path: try string(args, "path"), value: nil)
            return ["settings": try json(b.settings)]
        case "config.reveal":
            reveal(try string(args, "file"))
            return [:]
        case "theme.get":
            return ["theme": try json(b.theme), "defaults": try json(Theme())]
        case "theme.set":
            try b.setTheme(path: try string(args, "path"), value: args["value"] is NSNull ? nil : args["value"])
            return ["theme": try json(b.theme)]
        case "theme.reset":
            try b.setTheme(path: try string(args, "path"), value: nil)
            return ["theme": try json(b.theme)]

        case "history.query":
            let items = b.history?.query(args["text"] as? String ?? "", limit: args["limit"] as? Int ?? 100,
                                         offset: args["offset"] as? Int ?? 0, recent: args["sort"] as? String == "recent") ?? []
            return ["items": try json(items)]
        case "history.delete":
            if let u = URL(string: try string(args, "url")) { b.history?.delete(url: u) }
            return [:]
        case "history.clear":
            let range: [String: TimeInterval] = ["hour": 3600, "day": 86400, "week": 604_800]
            let r = args["range"] as? String ?? "all"
            b.history?.clear(since: range[r].map { Date().addingTimeInterval(-$0) })
            if range[r] == nil { Tab.forgetFavicons() }
            return [:]
        case "recovery.query":
            let reason = RecoveryReason(rawValue: args["reason"] as? String ?? "") ?? .archived
            let items = b.history?.recovery(reason: reason, text: args["text"] as? String ?? "",
                                             limit: args["limit"] as? Int ?? 100,
                                             offset: args["offset"] as? Int ?? 0) ?? []
            return ["items": try json(items)]
        case "recovery.restore":
            guard let id = UUID(uuidString: try string(args, "id")),
                  let record = b.history?.recovery(id: id),
                  record.reason.rawValue == (args["reason"] as? String ?? "archived"),
                  let window, window.restore(record) else { throw Failure(message: "tab could not be restored") }
            _ = b.history?.deleteRecovery(id: id)
            return [:]
        case "recovery.delete":
            if let id = UUID(uuidString: try string(args, "id")) { _ = b.history?.deleteRecovery(id: id) }
            return [:]
        case "recovery.clear":
            let reason = RecoveryReason(rawValue: args["reason"] as? String ?? "") ?? .archived
            b.history?.clearRecovery(reason: reason)
            return [:]

        case "downloads.list":
            return ["items": try json(b.downloads.items)]
        case "downloads.reveal":
            b.downloads.reveal(try string(args, "id")); return [:]
        case "downloads.open":
            b.downloads.open(try string(args, "id")); return [:]
        case "downloads.cancel":
            b.downloads.cancel(try string(args, "id")); return [:]
        case "downloads.clear":
            b.downloads.clearFinished(); return [:]

        case "snapshots.list":
            return ["items": try json(b.snapshots.list())]
        case "snapshots.take":
            guard let info = b.takeSnapshot(auto: false) else { throw Failure(message: "snapshot failed") }
            b.post(.anglSnapshots)
            return ["item": try json(info)]
        case "snapshots.open":
            b.openSnapshot(try b.snapshots.load(id: try string(args, "id")))
            return [:]
        case "snapshots.delete":
            b.snapshots.delete(id: try string(args, "id"))
            return [:]
        case "snapshots.export":
            let id = try string(args, "id")
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "angl-\(id).json"
            if await present(panel, window) == .OK, let url = panel.url {
                try JSONFile.write(try b.snapshots.load(id: id), to: url)
            }
            return [:]
        case "snapshots.import":
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            if await present(panel, window) == .OK, let url = panel.url {
                guard let snap = try JSONFile.read(Snapshot.self, from: url) else { throw Failure(message: "unreadable") }
                var copy = snap
                copy.auto = false
                _ = try b.snapshots.save(copy)
                b.post(.anglSnapshots)
            }
            return [:]

        case "workspaces.get":
            return try workspacesReply()
        case "workspaces.set":
            let data = try JSONSerialization.data(withJSONObject: args)
            let cfg = try JSONFile.decoder().decode(WorkspaceConfig.self, from: data)
            b.setWorkspaces(cfg)
            return try workspacesReply()
        case "containers.clearData":
            guard let id = UUID(uuidString: try string(args, "id")), let c = b.workspaces.container(id) else {
                throw Failure(message: "no such container")
            }
            await b.web.clearData(of: c)
            return [:]

        case "sites.list":
            let items = try b.sites.sites.sorted { $0.key < $1.key }.map { ["host": $0.key, "overrides": try json($0.value)] }
            return ["items": items]
        case "sites.set":
            let host = try string(args, "host").lowercased()
            let data = try JSONSerialization.data(withJSONObject: args["overrides"] ?? [:])
            let o = try JSONFile.decoder().decode(SiteOverrides.self, from: data)
            var s = b.sites
            s.sites[host] = o.isEmpty ? nil : o
            b.setSites(s)
            return [:]
        case "sites.reset":
            var s = b.sites
            s.sites[try string(args, "host").lowercased()] = nil
            b.setSites(s)
            return [:]

        case "blocking.status":
            return try blockingStatus()
        case "blocking.update":
            b.web.blocker.update(settings: b.settings)
            return try blockingStatus()

        case "passwords.status":
            return Passwords.shared.status
        case "passwords.login":
            guard let w = window?.window else { throw Failure(message: "no window") }
            await Passwords.shared.logIn(in: w)
            return Passwords.shared.status
        case "passwords.logout":
            Passwords.shared.logOut()
            return Passwords.shared.status

        case "engines.list":
            let items: [[String: Any]] = Engine.known.map {
                ["id": $0.id, "name": $0.name, "family": $0.family, "installed": Handoff.appURL(for: $0) != nil]
            }
            return ["items": items]

        case "profiles.list":
            var all = Paths.existingProfiles()
            if !all.contains(b.paths.profile) { all.append(b.paths.profile) }
            return ["current": b.paths.profile, "items": all.sorted()]
        case "profiles.open", "profiles.create":
            let name = try string(args, "name").lowercased()
            guard Paths.isValidProfileName(name) else { throw Failure(message: "use a-z, 0-9, - or _") }
            try Paths(profile: name).ensureDirectories()
            if cmd == "profiles.open" { try Profiles.launch(name) }
            return [:]

        case "about.info":
            let info = Bundle.main.infoDictionary ?? [:]
            let webkit = Bundle(identifier: "com.apple.WebKit")?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            return [
                "version": info["CFBundleShortVersionString"] as? String ?? "dev",
                "build": info["CFBundleVersion"] as? String ?? "dev",
                "webkit": webkit,
                "profile": b.paths.profile,
                "paths": ["config": b.paths.configDir.path, "state": b.paths.stateDir.path],
                "problems": b.problems,
            ]

        case "import.run":
            let (n, folder) = try await Importing.run(try string(args, "source"), window: window)
            return ["imported": n, "folder": folder]

        case "keys.list":
            let items: [[String: Any]] = Commands.all.filter { !$0.chord.isEmpty }.map {
                ["command": $0.id, "title": $0.title, "chord": $0.chordLabel]
            }
            return ["items": items]

        default:
            throw Failure(message: "unknown command \(cmd)")
        }
    }

    private static func workspacesReply() throws -> [String: Any] {
        let b = Browser.shared!
        return [
            "containers": try json(b.workspaces.containers),
            "workspaces": try json(b.workspaces.workspaces),
            "palette": b.theme.color.workspaces,
        ]
    }

    private static func blockingStatus() throws -> [String: Any] {
        let b = Browser.shared!
        let blocker = b.web.blocker
        return [
            "lists": try json(b.settings.blocking.lists),
            "rules": blocker.ruleCount,
            "updated": blocker.manifest.map { ISO8601DateFormatter().string(from: $0.generated) } ?? NSNull(),
            "busy": blocker.busy,
            "error": blocker.problem ?? NSNull(),
        ]
    }

    private static func reveal(_ file: String) {
        let p = Browser.shared.paths
        switch file {
        case "css":
            try? FileManager.default.createDirectory(at: p.cssDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(p.cssDir)
        default:
            let url = file == "theme" ? p.themeFile : file == "keys" ? p.keysFile : p.settingsFile
            if !FileManager.default.fileExists(atPath: url.path) { try? Data("{\n}\n".utf8).write(to: url) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    static func present(_ panel: NSSavePanel, _ window: BrowserWindowController?) async -> NSApplication.ModalResponse {
        if let w = window?.window { return await panel.beginSheetModal(for: w) }
        return panel.runModal()
    }

    /// Codable → JSON object for the reply.
    static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONFile.encoder().encode(value), options: [.fragmentsAllowed])
    }

    private static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let s = args[key] as? String, !s.isEmpty else { throw Failure(message: "missing \(key)") }
        return s
    }
}
