import AnglCore
import AppKit
import Network
import WebKit

/// Everything WebKit-wide: one data store per container, compiled block lists, injected scripts,
/// the angl:// scheme handler, and per-tab configuration.
@MainActor
final class WebEnvironment {
    let paths: Paths
    let blocker: ContentBlocker
    let scripts: InjectedScripts
    let pages = InternalPages()
    private var stores: [UUID: WKWebsiteDataStore] = [:]
    let userAgentApplicationName: String

    init(paths: Paths) {
        self.paths = paths
        blocker = ContentBlocker(paths: paths)
        scripts = InjectedScripts(paths: paths)
        // Safari's exact UA tail: WebKit already supplies the Mozilla/AppleWebKit prefix.
        let safari = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let version = (safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "26.0"
        userAgentApplicationName = "Version/\(version) Safari/605.1.15"
    }

    func start(settings: Settings) {
        blocker.load(settings: settings)
        _ = scripts.reloadUserCSS()
    }

    // MARK: Containers

    func dataStore(for container: Container) -> WKWebsiteDataStore {
        if let s = stores[container.id] { return s }
        let s = WKWebsiteDataStore(forIdentifier: UUID.dataStore(profile: paths.profile, container: container.id))
        apply(container.proxy, to: s)
        stores[container.id] = s
        return s
    }

    func applyProxies(_ cfg: WorkspaceConfig) {
        for c in cfg.containers { if let s = stores[c.id] { apply(c.proxy, to: s) } }
    }

    private func apply(_ proxy: Proxy?, to store: WKWebsiteDataStore) {
        guard let proxy, let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.port)) else {
            store.proxyConfigurations = []
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: port)
        switch proxy.kind {
        case .http: store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)]
        case .socks5: store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
        }
    }

    /// Wipe a container's cookies, storage and caches. Open tabs keep working (logged out).
    func clearData(of container: Container) async {
        let store = dataStore(for: container)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// A deleted container: erase its cookies and storage, then its store on disk.
    func removeStore(of id: UUID) async {
        let identifier = UUID.dataStore(profile: paths.profile, container: id)
        do {
            let store = stores.removeValue(forKey: id) ?? WKWebsiteDataStore(forIdentifier: identifier)
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
        // Fails while a web view still holds the store; its data is already gone by then.
        try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }

    /// Wipe one site's data (its registrable domain's records) in one container.
    func clearSiteData(host: String, in container: Container) async {
        let store = dataStore(for: container)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let matching = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
        await store.removeData(ofTypes: types, for: matching)
    }

    /// Forget-on-quit: wipe every site in one container except `keep` (registrable domains and
    /// their subdomains). Records are grouped by WebKit's display name, the registrable domain.
    func forgetSites(in container: Container, keeping keep: [String]) async {
        let store = dataStore(for: container)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let kept = Set(keep.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let doomed = await store.dataRecords(ofTypes: types).filter { r in
            let name = r.displayName.lowercased()
            return !kept.contains { name == $0 || name.hasSuffix("." + $0) }
        }
        if !doomed.isEmpty { await store.removeData(ofTypes: types, for: doomed) }
    }

    // MARK: Per-tab configuration

    /// A configuration for one tab. Each tab gets its own user content controller so per-site
    /// policy (block lists, scripts) can change per tab without touching others.
    func configuration(container: Container, settings: Settings) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = dataStore(for: container)
        cfg.userContentController = WKUserContentController()
        cfg.applicationNameForUserAgent = settings.privacy.safariUserAgent ? userAgentApplicationName : "angl"
        cfg.mediaTypesRequiringUserActionForPlayback = settings.content.blockAutoplay ? .all : []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.preferences.inactiveSchedulingPolicy = .suspend
        cfg.preferences.isFraudulentWebsiteWarningEnabled = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.setURLSchemeHandler(pages, forURLScheme: InternalPages.scheme)
        return cfg
    }

    @discardableResult
    func reloadUserCSS() -> Bool { scripts.reloadUserCSS() }
}

// MARK: - Content blocking

/// Compiles the bundled (or downloaded) filter-list chunks once into WebKit's rule-list store and
/// hands the compiled lists to tabs. Recompiles only when a chunk's content hash changes; rebuilds
/// when the enabled lists in Settings no longer match what's installed.
@MainActor
final class ContentBlocker {
    private let paths: Paths
    private(set) var lists: [WKContentRuleList] = []
    private(set) var fontList: WKContentRuleList?
    private(set) var manifest: FilterListManifest?
    private var advancedLookup: AdvancedRuleLookup?
    private(set) var busy = false
    private(set) var error: String?
    private let store = WKContentRuleListStore.default()!

    init(paths: Paths) { self.paths = paths }

    var ruleCount: Int { manifest?.chunks.map(\.rules).reduce(0, +) ?? 0 }
    func advancedEntries(for url: URL, enabled: Bool) -> [FilterListConverter.AdvancedEntry] {
        guard enabled, let advancedLookup else { return [] }
        return advancedLookup.entries(for: url)
    }

    /// A failed build/compile, or enabled lists the last build couldn't download.
    var problem: String? {
        if let error { return error }
        guard let failed = manifest?.failed, !failed.isEmpty else { return nil }
        return "couldn't download \(failed.joined(separator: ", "))"
    }

    private var wanted: [String] { FilterListManifest.sources(for: Browser.shared.settings.blocking.lists) }

    /// Newest manifest built from the enabled lists (downloaded, else the snapshot bundled in the
    /// app); failing that the newest of any, so pages stay protected while the right one builds.
    private func currentSource() -> (FilterListManifest, URL)? {
        let dirs = [paths.listsDir, Bundle.main.resourceURL?.appendingPathComponent("lists")].compactMap { $0 }
        let found = dirs.compactMap { dir -> (FilterListManifest, URL)? in
            guard let m = try? JSONFile.read(FilterListManifest.self, from: dir.appendingPathComponent("manifest.json")) else { return nil }
            return (m, dir)
        }
        let wanted = self.wanted
        let newest: ((FilterListManifest, URL), (FilterListManifest, URL)) -> Bool = { $0.0.generated < $1.0.generated }
        return found.filter { $0.0.sources == wanted }.max(by: newest) ?? found.max(by: newest)
    }

    private func openAdvanced(_ m: FilterListManifest, in dir: URL) {
        do {
            advancedLookup = try AdvancedRuleLookup(storageURL: dir.appendingPathComponent(m.advancedStorageFile),
                                                    indexURL: dir.appendingPathComponent(m.advancedIndexFile))
        } catch {
            advancedLookup = nil
            self.error = "advanced rules: \(error.localizedDescription)"
        }
    }

    func load(settings: Settings) {
        if let (manifest, directory) = currentSource() {
            self.manifest = manifest
            openAdvanced(manifest, in: directory)
        }
        NotificationCenter.default.addObserver(forName: .anglSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanged() }
        }
        Task {
            await compile()
            // Neither the downloaded nor the bundled lists match Settings (lists toggled, app updated).
            if !wanted.isEmpty, manifest?.sources != wanted { update(settings: Browser.shared.settings) }
        }
        Task {
            fontList = try? await store.compileContentRuleList(
                forIdentifier: "angl-fonts", encodedContentRuleList: FilterListConverter.fontBlockList())
        }
    }

    /// Settings changed: if the enabled lists differ from the installed build, switch to a matching
    /// build when one exists, else build one.
    private func selectionChanged() {
        let wanted = self.wanted
        if wanted.isEmpty {
            if manifest != nil || !lists.isEmpty { Task { await compile() } }
            return
        }
        guard manifest?.sources != wanted else { return }
        if currentSource()?.0.sources == wanted { Task { await compile() } }
        else { update(settings: Browser.shared.settings) }
    }

    private var compiling: Task<Void, Never>?

    /// Serialized, so a compile always finishes against the settings current when it started and
    /// the last one queued reflects the latest selection.
    private func compile() async {
        let previous = compiling
        let next = Task { await previous?.value; await compileNow() }
        compiling = next
        await next.value
    }

    private func compileNow() async {
        guard !wanted.isEmpty else {  // every list off: no blocking at all
            lists = []
            manifest = nil
            advancedLookup = nil
            error = nil
            Browser.shared.post(.anglBlocking)
            Browser.shared.windows.forEach { $0.refreshContentPolicies() }
            return
        }
        guard let (m, dir) = currentSource() else { error = "no block lists"; return }
        // load() already opened this manifest's index; only a new manifest needs a new one.
        if advancedLookup == nil || manifest?.generated != m.generated { openAdvanced(m, in: dir) }
        busy = true
        defer { busy = false; Browser.shared.post(.anglBlocking) }
        var found: [WKContentRuleList?] = []
        for chunk in m.chunks { found.append(try? await store.contentRuleList(forIdentifier: chunk.id)) }
        if found.contains(where: { $0 == nil }) {
            // Compiling happens in ListWorker's child, off this process's memory.
            let failure = await ListWorker.run(dir)
            found = []
            for chunk in m.chunks { found.append(try? await store.contentRuleList(forIdentifier: chunk.id)) }
            if found.contains(where: { $0 == nil }) {
                error = failure ?? "block lists didn't compile"
                // Keep the working build (and its compiled lists); a partial one only beats none.
                guard lists.isEmpty else { return }
                lists = found.compactMap { $0 }
                Browser.shared.windows.forEach { $0.refreshContentPolicies() }
                return
            }
        }
        lists = found.compactMap { $0 }
        manifest = m
        // Drop compiled lists from older manifests.
        let keep = Set(m.chunks.map(\.id)).union(["angl-fonts"])
        if let ids = await store.availableIdentifiers() {
            for id in ids where id.hasPrefix("angl-") && !keep.contains(id) {
                try? await store.removeContentRuleList(forIdentifier: id)
            }
        }
        Browser.shared.windows.forEach { $0.refreshContentPolicies() }
    }

    func updateIfStale(settings: Settings) {
        guard !busy, settings.blocking.updateEveryDays > 0, settings.blocking.lists.contains(where: \.enabled) else { return }
        let age = Date().timeIntervalSince(manifest?.generated ?? .distantPast)
        if age > settings.blocking.updateEveryDays * 86400 { update(settings: settings) }
    }

    func update(settings: Settings) {
        guard !busy else { return }
        let lists = settings.blocking.lists
        guard lists.contains(where: \.enabled) else { Task { await compile() }; return }
        busy = true
        error = nil
        Browser.shared.post(.anglBlocking)
        let dir = paths.listsDir
        Task {
            if let failure = await ListWorker.run(dir, lists: lists) { self.error = "update failed: \(failure)" }
            busy = false
            await compile()
            // Lists toggled again while this built.
            if wanted != FilterListManifest.sources(for: lists) { selectionChanged() }
        }
    }

    /// Install the right lists on a tab's controller for a page's policy.
    func apply(_ policy: SitePolicy, to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if policy.blocker { lists.forEach(controller.add) }
        if policy.blockRemoteFonts, let fontList { controller.add(fontList) }
    }
}

// MARK: - Injected scripts

/// Script sources angl injects. Ours run in an isolated content world; page scripts can't see them.
@MainActor
final class InjectedScripts {
    static let world = WKContentWorld.world(name: "angl")
    private let paths: Paths
    private var cache: [String: String] = [:]
    private(set) var globalCSS = ""
    private(set) var hostCSS: [(pattern: String, css: String)] = []
    /// Bumped whenever user CSS changes, so tabs know to reinstall scripts.
    private(set) var generation = 0

    init(paths: Paths) { self.paths = paths }

    func source(_ name: String) -> String {
        if let s = cache[name] { return s }
        let url = Bundle.main.resourceURL?.appendingPathComponent("web/inject/\(name)")
            ?? URL(fileURLWithPath: "Resources/web/inject/\(name)")
        let s = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        cache[name] = s
        return s
    }

    /// Reads ~/.config/angl/css: _global.css for every site, <host>.css (or *.suffix.css) per site.
    /// Returns whether anything changed.
    func reloadUserCSS() -> Bool {
        let dir = paths.cssDir
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".css") }.sorted() ?? []
        var global = ""
        var hosts: [(String, String)] = []
        for f in files where f != "_angl.css" {
            guard let css = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) else { continue }
            if f == "_global.css" { global = css } else { hosts.append((String(f.dropLast(4)).lowercased(), css)) }
        }
        let changed = global != globalCSS || hosts.map(\.0) != hostCSS.map(\.pattern) || hosts.map(\.1) != hostCSS.map(\.css)
        globalCSS = global
        hostCSS = hosts
        if changed { generation += 1 }
        return changed
    }

    func userCSS(for url: URL?) -> String {
        var css = globalCSS
        guard let host = url?.host()?.lowercased() else { return css }
        for (pattern, text) in hostCSS {
            let p = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
            if host == p || host.hasSuffix("." + p) { css += "\n" + text }
        }
        return css
    }

    static let squareCSS = "*, *::before, *::after { border-radius: 0 !important; }"

    /// JS that installs (or replaces) a <style> element as early as possible.
    static func styleScript(id: String, css: String) -> String {
        let literal = jsString(css)
        return """
        (() => {
          const put = () => {
            let s = document.getElementById("\(id)");
            if (!s) {
              s = document.createElement("style");
              s.id = "\(id)";
              (document.head || document.documentElement).appendChild(s);
            }
            s.textContent = \(literal);
          };
          if (document.documentElement) put();
          else document.addEventListener("readystatechange", put, { once: true });
        })();
        """
    }

    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
        guard let data, let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    static func volumeFactor(_ db: Double) -> Double { db <= -60 ? 0 : min(1, pow(10, db / 20)) }

    /// Rebuild a tab's scripts for a page's policy.
    func install(_ policy: SitePolicy, url: URL?, muted: Bool, nightAudio: Bool, twitchEmotes: Bool, advancedEntries: [FilterListConverter.AdvancedEntry] = [], on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        let w = InjectedScripts.world
        func add(_ src: String, _ time: WKUserScriptInjectionTime, mainOnly: Bool, world: WKContentWorld = w) {
            controller.addUserScript(WKUserScript(source: src, injectionTime: time, forMainFrameOnly: mainOnly, in: world))
        }
        add(source("status.js"), .atDocumentStart, mainOnly: false)
        let volume = source("volume.js")
            .replacingOccurrences(of: "__ANGL_FACTOR__", with: String(InjectedScripts.volumeFactor(policy.volumeDB)))
            .replacingOccurrences(of: "__ANGL_MUTED__", with: muted ? "true" : "false")
        if twitchEmotes, ["twitch.tv", "www.twitch.tv", "m.twitch.tv"].contains(url?.host?.lowercased() ?? "") {
            add(source("twitch-emotes.js"), .atDocumentStart, mainOnly: false, world: WKContentWorld.world(name: "angl-twitch"))
        }
        add(volume, .atDocumentStart, mainOnly: false)
        if policy.square { add(InjectedScripts.styleScript(id: "angl-square", css: InjectedScripts.squareCSS), .atDocumentStart, mainOnly: false) }
        let css = userCSS(for: url)
        if !css.isEmpty { add(InjectedScripts.styleScript(id: "angl-user", css: css), .atDocumentStart, mainOnly: false) }
        if policy.dark != .off {
            let dark = source("darkreader.js") + "\n" + source("dark.js").replacingOccurrences(of: "__ANGL_DARK_MODE__", with: policy.dark.rawValue)
            add(dark, policy.dark == .force ? .atDocumentStart : .atDocumentEnd, mainOnly: true)
        }
        if policy.javascript {
            add(source("passkey.js"), .atDocumentStart, mainOnly: true, world: .page)
            // Page world: it has to wrap the page's own MediaSource/SourceBuffer prototypes.
            if nightAudio { add(source("night-audio.js"), .atDocumentStart, mainOnly: false, world: .page) }
        }
        installAdvanced(advancedEntries) { src, time, mainOnly, world in
            add(src, time, mainOnly: mainOnly, world: world)
        }
        Passwords.shared.install(on: controller)
    }

    private func installAdvanced(
        _ entries: [FilterListConverter.AdvancedEntry],
        add: (String, WKUserScriptInjectionTime, Bool, WKContentWorld) -> Void
    ) {
        let calls = entries.compactMap { entry -> [String: Any]? in
            guard entry.kind == .scriptlet,
                  let invocation = FilterListConverter.scriptletInvocation(entry.content) else { return nil }
            return ["name": invocation.name, "args": invocation.arguments]
        }
        if !calls.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: calls),
           let json = String(data: data, encoding: .utf8) {
            let invoke = """
            (() => {
              try { if (window.top !== window && window.location.origin !== window.top.location.origin) return; } catch (_) { return; }
              for (const rule of \(json)) window.__anglAdGuardScriptlets?.invoke(rule.name, rule.args);
            })();
            """
            add(source("adguard-scriptlets.js") + "\n" + invoke, .atDocumentStart, false, .page)
        }

        let injectedCSS = entries.filter { $0.kind == .cssInject }.map(\.content).joined(separator: "\n")
        if !injectedCSS.isEmpty {
            add(InjectedScripts.styleScript(id: "angl-advanced-css", css: injectedCSS), .atDocumentStart, false, InjectedScripts.world)
        }

        let selectors = entries.filter { $0.kind == .extendedCSS }.map(\.content)
        guard !selectors.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: selectors),
              let json = String(data: data, encoding: .utf8) else { return }
        let css = """
        (() => {
          try { if (window.top !== window && window.location.origin !== window.top.location.origin) return; } catch (_) { return; }
          const selectors = \(json);
          let scheduled = false;
          const apply = () => {
            scheduled = false;
            for (const selector of selectors) {
              try { for (const element of document.querySelectorAll(selector)) element.style.setProperty("display", "none", "important"); } catch (_) {}
            }
          };
          const schedule = () => {
            if (!scheduled) { scheduled = true; requestAnimationFrame(apply); }
          };
          apply();
          new MutationObserver(schedule).observe(document, { childList: true, subtree: true });
        })();
        """
        add(css, .atDocumentStart, false, InjectedScripts.world)
}
}
