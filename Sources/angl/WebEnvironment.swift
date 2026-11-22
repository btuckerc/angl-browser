import AnglCore
import AppKit
import IOKit.ps
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
    /// Safari's exact UA tail: WebKit already supplies the Mozilla/AppleWebKit prefix. Loaded on
    /// first WebView creation so empty-window launches don't read Safari.app's Info.plist.
    lazy var userAgentApplicationName: String = {
        let safari = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let version = (safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    init(paths: Paths) {
        self.paths = paths
        blocker = ContentBlocker(paths: paths)
        scripts = InjectedScripts(paths: paths)
    }

    func start(settings: Settings) {
        blocker.load(settings: settings)
        _ = scripts.reloadUserCSS()
        watchPowerSource()
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
        if let pool = Self.processPool { cfg.setValue(pool, forKey: "processPool") }
        cfg.websiteDataStore = dataStore(for: container)
        cfg.userContentController = WKUserContentController()
        cfg.applicationNameForUserAgent = settings.privacy.safariUserAgent ? userAgentApplicationName : "angl"
        cfg.mediaTypesRequiringUserActionForPlayback = settings.content.blockAutoplay ? .all : []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.preferences.inactiveSchedulingPolicy = .suspend
        cfg.preferences.isFraudulentWebsiteWarningEnabled = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        applyRenderingRate(to: cfg.preferences)
        // Picture in Picture, off by default for apps (Safari turns it on): the PiP command and
        // auto PiP call the page's requestPictureInPicture, which WebKit refuses without it.
        Self.setFeature(Self.pictureInPictureFeature, true, on: cfg.preferences)
        // Progressive timer backoff in silent background tabs (off by default for WKWebView apps,
        // leaving hidden-tab setIntervals firing at 1 Hz indefinitely); WebKit exempts active audio.
        Self.setFeature(Self.hiddenTimerAutoIncreaseFeature, true, on: cfg.preferences)
        cfg.setURLSchemeHandler(pages, forURLScheme: InternalPages.scheme)
        return cfg
    }

    /// Every tab shares one process pool that keeps a launched web process ready, as Safari's
    /// does, so a new tab or a cross-site navigation doesn't wait on a cold process launch (~50 ms
    /// sooner to first paint). SPI, off by default for apps; WebKit without it keeps its default
    /// pool. Through the runtime because WKProcessPool's API is deprecated as a no-op.
    private static let processPool: NSObject? = {
        guard let configClass = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type,
              let poolClass = NSClassFromString("WKProcessPool") as? NSObject.Type else { return nil }
        let config = configClass.init()
        let make = NSSelectorFromString("_processPoolWithConfiguration:")
        guard config.responds(to: NSSelectorFromString("setPrewarmsProcessesAutomatically:")), poolClass.responds(to: make) else { return nil }
        config.setValue(true, forKey: "prewarmsProcessesAutomatically")
        return poolClass.perform(make, with: config)?.takeUnretainedValue() as? NSObject
    }()

    // MARK: Rendering rate

    /// On AC power pages render at the display's refresh rate (120 Hz on ProMotion) rather than
    /// WebKit's default of about 60 Hz: animation frames, hover effects and content revealed while
    /// scrolling update twice as often. On battery WebKit's default stays, and Low Power Mode and
    /// thermal throttling apply either way. SPI feature flag (Safari's Feature Flags "Prefer Page
    /// Rendering Updates near 60fps"); WebKit's default if absent.
    private(set) var rendersAtDisplayRate = WebEnvironment.onExternalPower()
    private var powerSource: CFRunLoopSource?

    private static let features: [NSObject] = {
        let list = NSSelectorFromString("_features")
        guard WKPreferences.responds(to: list) else { return [] }
        return WKPreferences.perform(list)?.takeUnretainedValue() as? [NSObject] ?? []
    }()
    private static func feature(_ key: String) -> NSObject? { features.first { $0.value(forKey: "key") as? String == key } }
    private static let near60FPSFeature = feature("PreferPageRenderingUpdatesNear60FPSEnabled")
    private static let pictureInPictureFeature = feature("AllowsPictureInPictureMediaPlayback")
    private static let hiddenTimerAutoIncreaseFeature = feature("HiddenPageDOMTimerThrottlingAutoIncreases")

    /// SPI feature flag switch; a missing flag (another WebKit) leaves WebKit's default.
    private static func setFeature(_ feature: NSObject?, _ on: Bool, on preferences: WKPreferences) {
        let set = NSSelectorFromString("_setEnabled:forFeature:")
        guard let feature, preferences.responds(to: set) else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(preferences.method(for: set), to: SetEnabled.self)(preferences, set, on, feature)
    }

    /// Also for open pages: WebKit picks the change up the next time the page is shown or swaps process.
    func applyRenderingRate(to preferences: WKPreferences) {
        Self.setFeature(Self.near60FPSFeature, !rendersAtDisplayRate, on: preferences)
    }

    /// Posts `.anglPower` when switching between AC and battery changes the rendering rate.
    private func watchPowerSource() {
        guard powerSource == nil, let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated { Unmanaged<WebEnvironment>.fromOpaque(context).takeUnretainedValue().powerSourceChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func powerSourceChanged() {
        let external = Self.onExternalPower()
        guard external != rendersAtDisplayRate else { return }
        rendersAtDisplayRate = external
        NotificationCenter.default.post(name: .anglPower, object: nil)
    }

    nonisolated private static func onExternalPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return type as String == kIOPMACPowerKey
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
    private static let fontJSON = FilterListConverter.fontBlockList()
    private static let fontID = FilterListConverter.ruleListIdentifier(prefix: "angl-fonts", encoded: fontJSON)
    private static let youtubeJSON = FilterListConverter.youtubeThumbnailBlockList()
    private static let youtubeID = FilterListConverter.ruleListIdentifier(prefix: "angl-youtube-frames", encoded: youtubeJSON)

    private let paths: Paths
    private(set) var lists: [WKContentRuleList] = []
    private(set) var fontList: WKContentRuleList?
    private(set) var youtubeList: WKContentRuleList?
    private(set) var manifest: FilterListManifest?
    private var advancedLookup: AdvancedRuleLookup?
    private var advancedLoadedKey: (storage: URL, index: URL)?
    private var isUpdating = false
    private var isCompiling = false
    var busy: Bool { isUpdating || isCompiling }
    private(set) var error: String?
    /// Opened on demand so empty-window launches don't boot WebKit's rule-list store or JSC scavenger.
    private lazy var store: WKContentRuleListStore = WKContentRuleListStore.default()!
    private var cachedReadyTask: Task<Void, Never>?
    private var fontTask: Task<WKContentRuleList?, Never>?
    private var youtubeTask: Task<WKContentRuleList?, Never>?
    private var compileDepth = 0
    private var stateGeneration = 0

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

    private static func sameManifest(_ a: FilterListManifest, _ b: FilterListManifest) -> Bool {
        a.generated == b.generated
            && a.chunks.map(\.id) == b.chunks.map(\.id)
            && a.advancedStorageFile == b.advancedStorageFile
            && a.advancedIndexFile == b.advancedIndexFile
            && a.sources == b.sources
    }

    private func availableSources() -> [(FilterListManifest, URL)] {
        let dirs = [paths.listsDir, Bundle.main.resourceURL?.appendingPathComponent("lists")].compactMap { $0 }
        return dirs.compactMap { dir -> (FilterListManifest, URL)? in
            guard let m = try? JSONFile.read(FilterListManifest.self, from: dir.appendingPathComponent("manifest.json")) else { return nil }
            return (m, dir)
        }
    }

    private func alternateSource(excluding dir: URL) -> (FilterListManifest, URL)? {
        availableSources().first { $0.1 != dir }
    }

    /// Newest manifest built from the enabled lists (downloaded, else the snapshot bundled in the
    /// app); failing that the newest of any, so pages stay protected while the right one builds.
    private func currentSource() -> (FilterListManifest, URL)? {
        let found = availableSources()
        let wanted = self.wanted
        let newest: ((FilterListManifest, URL), (FilterListManifest, URL)) -> Bool = { $0.0.generated < $1.0.generated }
        return found.filter { $0.0.sources == wanted }.max(by: newest) ?? found.max(by: newest)
    }

    private func loadAdvanced(_ m: FilterListManifest, in dir: URL) -> Result<AdvancedRuleLookup, Error> {
        let storageURL = dir.appendingPathComponent(m.advancedStorageFile)
        let indexURL = dir.appendingPathComponent(m.advancedIndexFile)
        if let existing = advancedLookup, advancedLoadedKey?.storage == storageURL, advancedLoadedKey?.index == indexURL {
            return .success(existing)
        }
        do {
            return .success(try AdvancedRuleLookup(storageURL: storageURL, indexURL: indexURL))
        } catch {
            return .failure(error)
        }
    }

    private func installAdvanced(_ lookup: AdvancedRuleLookup?, for m: FilterListManifest, in dir: URL) {
        if let lookup {
            advancedLookup = lookup
            advancedLoadedKey = (dir.appendingPathComponent(m.advancedStorageFile), dir.appendingPathComponent(m.advancedIndexFile))
        } else {
            clearAdvanced()
        }
    }

    private func clearAdvanced() {
        advancedLookup = nil
        advancedLoadedKey = nil
    }

    func load(settings: Settings) {
        if !wanted.isEmpty, let (m, _) = currentSource() { manifest = m }
        NotificationCenter.default.addObserver(forName: .anglSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanged() }
        }
    }

    /// Starts looking up already-compiled lists in WebKit's store immediately (all lookups fan out
    /// onto WebKit's background store queue right away, in parallel with WebView creation).
    /// Serialized through `compiling` so settings changes or updates cannot race with startup lookup.
    func prepare() {
        guard cachedReadyTask == nil else { return }
        let store = self.store
        let fontLookup = ensureSmallList(id: Self.fontID, encoded: Self.fontJSON, current: fontList, slot: &fontTask, store: store)
        let youtubeLookup = ensureSmallList(id: Self.youtubeID, encoded: Self.youtubeJSON, current: youtubeList, slot: &youtubeTask, store: store)
        let wanted = self.wanted
        let source = wanted.isEmpty ? nil : currentSource()
        let chunkLookups = source.map { src in src.0.chunks.map { startLookup(store: store, id: $0.id) } } ?? []
        let previous = compiling
        compileDepth += 1
        let task = Task {
            defer {
                self.compileDepth -= 1
                if self.compileDepth == 0 { self.compiling = nil }
            }
            await previous?.value
            await finishPrepare(fontLookup: fontLookup, youtubeLookup: youtubeLookup,
                                wanted: wanted, source: source, chunkLookups: chunkLookups)
        }
        compiling = task
        cachedReadyTask = task
    }

    /// Waits only for the rule lists a page's policy will actually install (never blocking opted-out
    /// sites on cold subscription compilation, and never blocking on network downloads).
    func waitUntilReady(mainLists: Bool, fonts: Bool, youtube: Bool) async {
        if mainLists {
            prepare()
            if lists.isEmpty, let task = compiling {
                await task.value
            } else {
                await cachedReadyTask?.value
            }
            return
        }
        if fonts, fontList == nil {
            let task = ensureSmallList(id: Self.fontID, encoded: Self.fontJSON, current: fontList, slot: &fontTask, store: store)
            if let hit = await task.value { fontList = hit }
        }
        if youtube, youtubeList == nil {
            let task = ensureSmallList(id: Self.youtubeID, encoded: Self.youtubeJSON, current: youtubeList, slot: &youtubeTask, store: store)
            if let hit = await task.value { youtubeList = hit }
        }
    }

    private func ensureSmallList(
        id: String,
        encoded: String,
        current: WKContentRuleList?,
        slot: inout Task<WKContentRuleList?, Never>?,
        store: WKContentRuleListStore
    ) -> Task<WKContentRuleList?, Never> {
        if let current { return Task { current } }
        if let existing = slot { return existing }
        let lookup = startLookup(store: store, id: id)
        let task = Task<WKContentRuleList?, Never> { @MainActor in
            if let hit = await lookup.value { return hit }
            return try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: encoded)
        }
        slot = task
        return task
    }

    /// Begins a WebKit rule-list lookup synchronously so WebKit's background queue runs while the
    /// main thread builds the web view.
    private func startLookup(store: WKContentRuleListStore, id: String) -> Task<WKContentRuleList?, Never> {
        @MainActor final class Box {
            var result: WKContentRuleList??
            var resume: ((WKContentRuleList?) -> Void)?
        }
        let box = Box()
        store.lookUpContentRuleList(forIdentifier: id) { list, _ in
            MainActor.assumeIsolated {
                if let r = box.resume {
                    box.resume = nil
                    r(list)
                } else {
                    box.result = .some(list)
                }
            }
        }
        return Task { @MainActor in
            if let done = box.result { return done }
            return await withCheckedContinuation { cont in
                if let done = box.result { cont.resume(returning: done) }
                else { box.resume = { cont.resume(returning: $0) } }
            }
        }
    }

    private func finishPrepare(
        fontLookup: Task<WKContentRuleList?, Never>,
        youtubeLookup: Task<WKContentRuleList?, Never>,
        wanted: [String],
        source: (FilterListManifest, URL)?,
        chunkLookups: [Task<WKContentRuleList?, Never>]
    ) async {
        if fontList == nil { fontList = await fontLookup.value }
        if youtubeList == nil { youtubeList = await youtubeLookup.value }
        // Re-check live settings after awaiting lookups: settings or an update may have changed.
        if self.wanted != wanted {
            await compileNow()
            return
        }
        guard !wanted.isEmpty else {
            lists = []
            manifest = nil
            clearAdvanced()
            error = nil
            stateGeneration += 1
            Browser.shared.windows.forEach { $0.refreshContentPolicies() }
            return
        }
        guard let (m, dir) = source else {
            error = "no block lists"
            Task { [weak self] in self?.update(settings: Browser.shared.settings) }
            return
        }
        // If an earlier compile/update already installed this exact manifest completely, keep it (and its error).
        if let cur = self.manifest, Self.sameManifest(cur, m), self.lists.count == m.chunks.count,
           (!Browser.shared.settings.blocking.advanced || self.advancedLookup != nil) {
            return
        }
        var found: [WKContentRuleList?] = []
        found.reserveCapacity(chunkLookups.count)
        for lookup in chunkLookups { found.append(await lookup.value) }
        // Re-check live settings and manifest identity after awaiting chunk lookups.
        guard self.wanted == wanted, let current = currentSource(), Self.sameManifest(current.0, m), current.1 == dir else {
            if let current = currentSource(), let cur = self.manifest, Self.sameManifest(cur, current.0),
               self.lists.count == current.0.chunks.count, self.wanted == cur.sources {
                return
            }
            await compileNow()
            return
        }
        if !found.contains(where: { $0 == nil }) {
            let advResult = loadAdvanced(m, in: dir)
            let advOK = (try? advResult.get()) != nil
            if advOK || !Browser.shared.settings.blocking.advanced {
                lists = found.compactMap { $0 }
                manifest = m
                let preserved = error?.hasPrefix("update failed:") == true ? error : nil
                error = preserved
                installAdvanced(try? advResult.get(), for: m, in: dir)
                stateGeneration += 1
                let gen = stateGeneration
                Browser.shared.windows.forEach { $0.refreshContentPolicies() }
                let keep = Set(m.chunks.map(\.id)).union([Self.fontID, Self.youtubeID])
                Task { [weak self] in
                    guard let self, self.stateGeneration == gen else { return }
                    await self.pruneStore(keeping: keep)
                    if self.stateGeneration == gen, !self.wanted.isEmpty, self.manifest?.sources != self.wanted {
                        self.update(settings: Browser.shared.settings)
                    }
                }
                return
            }
        }
        // Cold/partial cache miss or unreadable advanced index: compile (with alternate fallback)
        // before letting the first protected page navigate so blocking is active from byte 0.
        await compileNow()
        if !self.wanted.isEmpty, self.manifest?.sources != self.wanted {
            Task { [weak self] in self?.update(settings: Browser.shared.settings) }
        }
    }

    /// Keeps rule-list chunks needed by any existing profile or the bundled snapshot, so switching
    /// profiles sharing WebKit's default store does not evict another profile's compiled lists.
    private func allRetainedIdentifiers(including keep: Set<String>) -> Set<String> {
        var retained = keep
        var dirs = Paths.existingProfiles().map { Paths(profile: $0).listsDir }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("lists") { dirs.append(bundled) }
        for dir in dirs {
            if let m = try? JSONFile.read(FilterListManifest.self, from: dir.appendingPathComponent("manifest.json")) {
                retained.formUnion(m.chunks.map(\.id))
            }
        }
        return retained
    }

    /// Queries the store inventory *before* reading all profiles' manifests: because ListWorker writes
    /// manifest.json before compiling its chunks, any chunk present in `ids` already has its manifest
    /// on disk when `allRetainedIdentifiers` scans, preventing concurrent-profile eviction.
    private func pruneStore(keeping keep: Set<String>) async {
        guard let ids = await store.availableIdentifiers() else { return }
        let retained = allRetainedIdentifiers(including: keep)
        for id in ids where id.hasPrefix("angl-") && !retained.contains(id) {
            try? await store.removeContentRuleList(forIdentifier: id)
        }
    }

    /// Settings changed: if the enabled lists differ from the installed build, switch to a matching
    /// build when one exists, else build one.
    private func selectionChanged() {
        let wanted = self.wanted
        if wanted.isEmpty {
            if manifest != nil || !lists.isEmpty || compileDepth > 0 { Task { await compile() } }
            return
        }
        guard manifest?.sources != wanted || compileDepth > 0 else { return }
        if currentSource()?.0.sources == wanted { Task { await compile() } }
        else { update(settings: Browser.shared.settings) }
    }

    private var compiling: Task<Void, Never>?

    /// Serialized, so a compile always finishes against the settings current when it started and
    /// the last one queued reflects the latest selection.
    private func compile(preservingError: String? = nil) async {
        let previous = compiling
        compileDepth += 1
        let next = Task {
            defer {
                self.compileDepth -= 1
                if self.compileDepth == 0 { self.compiling = nil }
            }
            await previous?.value
            await compileNow(preservingError: preservingError)
        }
        compiling = next
        await next.value
    }

    private func resolveChunks(for m: FilterListManifest, in dir: URL) async -> (lists: [WKContentRuleList], complete: Bool, error: String?) {
        var found: [WKContentRuleList?] = []
        for chunk in m.chunks { found.append(try? await store.contentRuleList(forIdentifier: chunk.id)) }
        if !found.contains(where: { $0 == nil }) {
            return (found.compactMap { $0 }, true, nil)
        }
        // Compiling happens in ListWorker's child, off this process's memory.
        let failure = await ListWorker.run(dir, timeout: 60)
        found = []
        for chunk in m.chunks { found.append(try? await store.contentRuleList(forIdentifier: chunk.id)) }
        let complete = !found.contains(where: { $0 == nil })
        return (found.compactMap { $0 }, complete, complete ? nil : (failure ?? "block lists didn't compile"))
    }

    private func compileNow(preservingError: String? = nil) async {
        let wantedAtStart = self.wanted
        if fontList == nil {
            fontList = await ensureSmallList(id: Self.fontID, encoded: Self.fontJSON, current: fontList, slot: &fontTask, store: store).value
        }
        if youtubeList == nil {
            youtubeList = await ensureSmallList(id: Self.youtubeID, encoded: Self.youtubeJSON, current: youtubeList, slot: &youtubeTask, store: store).value
        }
        guard !wanted.isEmpty else {  // every list off: no blocking at all
            lists = []
            manifest = nil
            clearAdvanced()
            error = nil
            stateGeneration += 1
            Browser.shared.post(.anglBlocking)
            Browser.shared.windows.forEach { $0.refreshContentPolicies() }
            return
        }
        guard let (m, dir) = currentSource() else {
            error = preservingError ?? "no block lists"
            Browser.shared.post(.anglBlocking)
            return
        }
        isCompiling = true
        defer { isCompiling = false; Browser.shared.post(.anglBlocking) }
        let res = await resolveChunks(for: m, in: dir)
        // Revalidate live selection after async lookup/compile so rapid toggles cannot install stale lists.
        if self.wanted != wantedAtStart {
            isCompiling = false
            await compileNow()
            return
        }
        let advResult = loadAdvanced(m, in: dir)
        let advFailed: String? = {
            if case .failure(let e) = advResult, Browser.shared.settings.blocking.advanced {
                return "advanced rules: \(e.localizedDescription)"
            }
            return nil
        }()
        if !res.complete || advFailed != nil {
            let err = preservingError ?? res.error ?? advFailed ?? "block lists didn't compile"
            error = err
            // Keep the working build (and its compiled lists + matching advanced index); if none is
            // installed yet, try the alternate local manifest (bundled or downloaded) before partial chunks.
            guard lists.isEmpty else { return }
            if let (am, adir) = alternateSource(excluding: dir) {
                let fallback = await resolveChunks(for: am, in: adir)
                if self.wanted != wantedAtStart {
                    isCompiling = false
                    await compileNow()
                    return
                }
                let altAdv = loadAdvanced(am, in: adir)
                let altAdvOK = (try? altAdv.get()) != nil || !Browser.shared.settings.blocking.advanced
                if fallback.complete && altAdvOK {
                    lists = fallback.lists
                    manifest = am
                    installAdvanced(try? altAdv.get(), for: am, in: adir)
                    stateGeneration += 1
                    Browser.shared.windows.forEach { $0.refreshContentPolicies() }
                    if dir == paths.listsDir, preservingError == nil {
                        Task { [weak self] in self?.update(settings: Browser.shared.settings) }
                    }
                    return
                }
            }
            lists = res.lists
            manifest = m
            installAdvanced(try? advResult.get(), for: m, in: dir)
            stateGeneration += 1
            Browser.shared.windows.forEach { $0.refreshContentPolicies() }
            return
        }
        lists = res.lists
        manifest = m
        error = preservingError
        installAdvanced(try? advResult.get(), for: m, in: dir)
        stateGeneration += 1
        // Drop compiled lists from older manifests (keeping chunks needed by other profiles).
        let keep = Set(m.chunks.map(\.id)).union([Self.fontID, Self.youtubeID])
        await pruneStore(keeping: keep)
        Browser.shared.windows.forEach { $0.refreshContentPolicies() }
    }

    func updateIfStale(settings: Settings) {
        guard !busy, settings.blocking.updateEveryDays > 0, settings.blocking.lists.contains(where: \.enabled) else { return }
        let age = Date().timeIntervalSince(manifest?.generated ?? .distantPast)
        if age > settings.blocking.updateEveryDays * 86400 { update(settings: settings) }
    }

    func update(settings: Settings) {
        guard !isUpdating else { return }
        let lists = settings.blocking.lists
        guard lists.contains(where: \.enabled) else { Task { await compile() }; return }
        isUpdating = true
        error = nil
        Browser.shared.post(.anglBlocking)
        let dir = paths.listsDir
        Task {
            defer {
                isUpdating = false
                Browser.shared.post(.anglBlocking)
            }
            let failure = await ListWorker.run(dir, lists: lists)
            let updateError = failure.map { "update failed: \($0)" }
            await compile(preservingError: updateError)
            // Lists toggled again while this built.
            if wanted != FilterListManifest.sources(for: lists) { selectionChanged() }
        }
    }

    /// Install the right lists on a tab's controller for a page's policy.
    func apply(_ policy: SitePolicy, youtubeFrames: Bool, to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if policy.blocker { lists.forEach(controller.add) }
        if policy.blockRemoteFonts, let fontList { controller.add(fontList) }
        if youtubeFrames, let youtubeList { controller.add(youtubeList) }
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

    /// JS that installs (or replaces) a <style> element as early as possible. `sameOriginOnly`
    /// skips frames whose origin differs from the top page's (rules meant for the top site).
    static func styleScript(id: String, css: String, sameOriginOnly: Bool = false) -> String {
        let literal = jsString(css)
        let guardFrame = sameOriginOnly
            ? "try { if (window.top !== window && window.location.origin !== window.top.location.origin) return; } catch (_) { return; }\n  "
            : ""
        return """
        (() => {
          \(guardFrame)const put = () => {
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

    /// One user script as installed. A tab reinstalls only when its page needs a different set.
    struct Script: Equatable {
        let source: String
        let time: WKUserScriptInjectionTime
        let mainOnly: Bool
        let world: WKContentWorld

        static func == (a: Script, b: Script) -> Bool {
            a.time == b.time && a.mainOnly == b.mainOnly && a.world === b.world && a.source == b.source
        }
    }

    /// The scripts a page gets for its policy, in injection order.
    func scripts(_ policy: SitePolicy, url: URL?, muted: Bool, content: Settings.Content, twitchEmotes: Bool,
                 advancedEntries: [FilterListConverter.AdvancedEntry] = []) -> [Script] {
        var out: [Script] = []
        let w = InjectedScripts.world
        func add(_ src: String, _ time: WKUserScriptInjectionTime, mainOnly: Bool, world: WKContentWorld = w) {
            out.append(Script(source: src, time: time, mainOnly: mainOnly, world: world))
        }
        add(source("status.js"), .atDocumentStart, mainOnly: false)
        let volume = source("volume.js")
            .replacingOccurrences(of: "__ANGL_FACTOR__", with: String(InjectedScripts.volumeFactor(policy.volumeDB)))
            .replacingOccurrences(of: "__ANGL_MUTED__", with: muted ? "true" : "false")
        if twitchEmotes, InjectedScripts.isTwitch(url) {
            add(source("twitch-emotes.js"), .atDocumentStart, mainOnly: false, world: InjectedScripts.twitchWorld)
        }
        let youtube = InjectedScripts.isYouTube(url)
        if content.youtubeFrames, youtube {
            add(source("youtube-frames.js"), .atDocumentStart, mainOnly: true)
        }
        add(volume, .atDocumentStart, mainOnly: false)
        if policy.square { add(InjectedScripts.squareScript, .atDocumentStart, mainOnly: false) }
        let css = userCSS(for: url)
        if !css.isEmpty { add(InjectedScripts.styleScript(id: "angl-user", css: css), .atDocumentStart, mainOnly: false) }
        if policy.dark != .off {
            let dark = source("darkreader.js") + "\n" + source("dark.js").replacingOccurrences(of: "__ANGL_DARK_MODE__", with: policy.dark.rawValue)
            add(dark, policy.dark == .force ? .atDocumentStart : .atDocumentEnd, mainOnly: true)
        }
        if policy.javascript {
            add(source("passkey.js"), .atDocumentStart, mainOnly: true, world: .page)
            // Page world: it has to wrap the page's own MediaSource/SourceBuffer prototypes.
            if content.nightAudio { add(source("night-audio.js"), .atDocumentStart, mainOnly: false, world: .page) }
            // Instant full screen replaces the page's Fullscreen API (page world); the gate in
            // angl's world holds the app handler. Iframes keep WebKit's full screen.
            if content.fullscreen != .native {
                add(source("fullscreen.js"), .atDocumentStart, mainOnly: true, world: .page)
                add(source("fullscreen-gate.js"), .atDocumentStart, mainOnly: true)
            }
            if youtube, content.youtubeQuality != .auto {
                add(source("youtube-quality.js").replacingOccurrences(of: "__ANGL_YT_QUALITY__", with: content.youtubeQuality.rawValue),
                    .atDocumentStart, mainOnly: true, world: .page)
            }
        }
        advanced(advancedEntries) { src, time, mainOnly, world in add(src, time, mainOnly: mainOnly, world: world) }
        if Passwords.shared.enabled { add(source("passwords.js"), .atDocumentStart, mainOnly: false, world: Passwords.world) }
        return out
    }

    static func isYouTube(_ url: URL?) -> Bool {
        ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(url?.host?.lowercased() ?? "")
    }

    static func isTwitch(_ url: URL?) -> Bool {
        ["twitch.tv", "www.twitch.tv", "m.twitch.tv"].contains(url?.host?.lowercased() ?? "")
    }

    static let twitchWorld = WKContentWorld.world(name: "angl-twitch")
    private static let squareScript = styleScript(id: "angl-square", css: squareCSS)

    func install(_ scripts: [Script], on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        for s in scripts {
            controller.addUserScript(WKUserScript(source: s.source, injectionTime: s.time, forMainFrameOnly: s.mainOnly, in: s.world))
        }
    }

    private lazy var scriptlets = ScriptletLibrary(source("adguard-scriptlets.js"))

    private func advanced(
        _ entries: [FilterListConverter.AdvancedEntry],
        add: (String, WKUserScriptInjectionTime, Bool, WKContentWorld) -> Void
    ) {
        let calls = entries.compactMap { entry -> FilterListConverter.ScriptletInvocation? in
            entry.kind == .scriptlet ? FilterListConverter.scriptletInvocation(entry.content) : nil
        }
        if !calls.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: calls.map { ["name": $0.name, "args": $0.arguments] }),
           let json = String(data: data, encoding: .utf8) {
            let invoke = """
            (() => {
              try { if (window.top !== window && window.location.origin !== window.top.location.origin) return; } catch (_) { return; }
              for (const rule of \(json)) window.__anglAdGuardScriptlets?.invoke(rule.name, rule.args);
            })();
            """
            add(scriptlets.source(for: calls.map(\.name)) + "\n" + invoke, .atDocumentStart, false, .page)
        }

        let injectedCSS = entries.filter { $0.kind == .cssInject }.map(\.content).joined(separator: "\n")
        if !injectedCSS.isEmpty {
            add(InjectedScripts.styleScript(id: "angl-advanced-css", css: injectedCSS), .atDocumentStart, false, InjectedScripts.world)
        }

        // Extended-CSS hiding as a stylesheet: the style engine applies it to elements as they
        // appear, with no observer or per-frame queries. One rule per selector, so the CSS parser
        // drops only the selectors it can't use (procedural ones like :contains, which never matched).
        let hidden = entries.filter { $0.kind == .extendedCSS }
            .map { $0.content.replacingOccurrences(of: ":-abp-has(", with: ":has(") }
            .filter { !$0.contains("{") && !$0.contains("}") && !$0.contains("/*") }
            .map { "\($0) { display: none !important; }" }
        if !hidden.isEmpty {
            add(InjectedScripts.styleScript(id: "angl-advanced-hide", css: hidden.joined(separator: "\n"), sameOriginOnly: true),
                .atDocumentStart, false, InjectedScripts.world)
        }
    }
}
