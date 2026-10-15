import AnglCore
import AppKit
import WebKit

/// The live side of a tab node: a web view (only while loaded), its delegates and page policy.
/// Unloaded tabs keep their node (title, URL, interactionState) and cost no WebContent process.
@MainActor
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let node: TabNode
    unowned let owner: BrowserWindowController
    private(set) var webView: AnglWebView?
    private var observers: [NSKeyValueObservation] = []
    private(set) var policy: SitePolicy?
    private var appliedKey: String?
    /// night-audio.js is in the tab's scripts (it runs from the next load on).
    private var nightAudioInstalled = false
    var muted = false
    /// Frames (status.js ids) that have reported media, and whether it plays now. WebKit's audio flag
    /// covers WebAudio and detached media; the frames are its fallback and carry volume updates to iframes.
    private var mediaFrames: [String: (info: WKFrameInfo, playing: Bool)] = [:]
    private var mediaPlaying: Bool { mediaFrames.values.contains { $0.playing } }
    private var playingAudio = false
    /// Speaker glyph: WebKit's audio flag, or the media frames when that private API is missing.
    var isPlaying: Bool { Tab.observesAudio ? playingAudio : mediaPlaying }
    var favicon: NSImage?
    private var iconHost: String?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    /// href of the link the page's context menu opened on (from status.js).
    fileprivate(set) var contextLink: URL?

    init(node: TabNode, owner: BrowserWindowController) {
        self.node = node
        self.owner = owner
        favicon = Tab.storedFavicon(for: node.url)
        iconHost = node.url?.host()
    }

    var browser: Browser { Browser.shared }
    var isLoaded: Bool { webView != nil }

    var protectsFromAutomaticRemoval: Bool {
        guard let webView else { return false }
        return mediaPlaying || playingAudio
            || webView.cameraCaptureState == .active || webView.microphoneCaptureState == .active
    }
    var url: URL? { webView?.url ?? node.url }
    var displayTitle: String {
        if !node.title.isEmpty { return node.title }
        if let u = url { return u.scheme == InternalPages.scheme ? InternalPages.title(for: u) : Omnibox.display(u) }
        return "New Tab"
    }
    var container: Container { owner.container(for: node) }

    // MARK: Lifecycle

    /// Create the web view (restoring back/forward state when we have it) and start loading.
    func load() {
        guard webView == nil else { return }
        let wv = makeWebView(configuration: nil)
        // File pages load fresh: restored back/forward state carries no file read access, and WebKit
        // kills the WebContent process over it (a crash on every reload).
        if let state = node.interactionState, node.url?.isFileURL != true {
            wv.interactionState = state
        } else if let url = node.url {
            navigate(url)
        }
    }

    func navigate(_ url: URL) {
        // Persist now: KVO later sees the same URL, and a load that never finishes has no didFinish.
        if node.url != url { browser.markSessionDirty() }
        node.url = url
        if webView == nil { _ = makeWebView(configuration: nil) }
        if url.isFileURL {
            webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView?.load(URLRequest(url: url))
        }
    }

    /// Drop the web view, keeping enough state to come back where we were.
    func unload() {
        Passwords.shared.pageHidden(in: self)
        guard let wv = webView else { return }
        captureState()
        observers.removeAll()
        if Tab.observesAudio { wv.removeObserver(self, forKeyPath: Tab.audioKey) }
        mediaFrames = [:]
        playingAudio = false
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        wv.configuration.userContentController.removeAllScriptMessageHandlers()
        wv.removeFromSuperview()
        webView = nil
        isLoading = false
        progress = 0
        appliedKey = nil
        owner.tabChanged(self)
    }

    func captureState() {
        guard let wv = webView else { return }
        if let data = wv.interactionState as? Data { node.interactionState = data }
        if let u = wv.url { node.url = u }
    }

    func reload(fromOrigin: Bool) {
        guard let wv = webView else { load(); return }
        appliedKey = nil
        if wv.url == nil, let u = node.url { navigate(u); return }
        _ = fromOrigin ? wv.reloadFromOrigin() : wv.reload()
    }

    /// Build the web view. `configuration` is WebKit's for window.open children; it must be used as is
    /// (apart from a fresh user content controller so per-tab policy stays per tab).
    @discardableResult
    func makeWebView(configuration: WKWebViewConfiguration?) -> AnglWebView {
        let cfg = configuration ?? browser.web.configuration(container: container, settings: browser.settings)
        if configuration != nil { cfg.userContentController = WKUserContentController() }
        let wv = AnglWebView(frame: .zero, configuration: cfg)
        wv.tab = self
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.isInspectable = browser.settings.developer.inspector
        wv.underPageBackgroundColor = browser.style.base
        wv.setValue(false, forKey: "drawsBackground")
        webView = wv
        installHandlers(isInternal: false)
        observers = [
            wv.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let t = wv.title, !t.isEmpty else { return }
                    self.node.title = t
                    if let u = wv.url { self.browser.history?.updateTitle(url: u, title: t) }
                    self.owner.tabChanged(self)
                }
            },
            wv.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let u = wv.url else { return }
                    // Same-document navigation (pushState) has no didFinish; persist the route. Titles
                    // aren't persisted here: some pages tick them every second, and a load refreshes them.
                    if u != self.node.url { self.browser.markSessionDirty() }
                    self.node.url = u
                    self.owner.tabChanged(self)
                }
            },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.progress = wv.estimatedProgress
                    self.owner.progressChanged(self)
                }
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = wv.isLoading
                    self.owner.tabChanged(self)
                    self.owner.progressChanged(self)
                }
            },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self.map { $0.owner.tabChanged($0) } }
            },
            wv.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self.map { $0.owner.tabChanged($0) } }
            },
        ]
        if Tab.observesAudio { wv.addObserver(self, forKeyPath: Tab.audioKey, options: [.new], context: nil) }
        applyNativeMute()
        owner.webViewCreated(for: self)
        return wv
    }

    // MARK: Audio (private WebKit API, the same Safari's tab audio indicator uses; guarded so
    // a WebKit without it falls back to status.js media events and element muting)

    private static let audioKey = "_isPlayingAudio"
    private static let observesAudio = WKWebView.instancesRespond(to: NSSelectorFromString(audioKey))
    private static let setPageMuted = NSSelectorFromString("_setPageMuted:")
    /// Page-level mute covers WebAudio as well as media elements.
    static let nativeMute = WKWebView.instancesRespond(to: setPageMuted)
        && WKWebView.instancesRespond(to: NSSelectorFromString("_mediaMutedState"))

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let playing = (change?[.newKey] as? NSNumber)?.boolValue ?? false
        let source = (object as AnyObject?).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
            guard source != nil, source == webView.map(ObjectIdentifier.init), playing != playingAudio else { return }
            playingAudio = playing
            owner.tabChanged(self)
        }
    }

    /// Sets only the audio bit of WebKit's _WKMediaMutedState mask (audio = 1), leaving capture bits alone.
    private func applyNativeMute() {
        guard Tab.nativeMute, let wv = webView else { return }
        let current = (wv.value(forKey: "_mediaMutedState") as? NSNumber)?.uintValue ?? 0
        let next = muted ? current | 1 : current & ~1
        guard next != current else { return }
        typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(wv.method(for: Tab.setPageMuted), to: SetMuted.self)(wv, Tab.setPageMuted, next)
    }

    /// Element muting in volume.js, only when WebKit can't mute the page.
    private var scriptMuted: Bool { muted && !Tab.nativeMute }

    private func installHandlers(isInternal: Bool) {
        guard let c = webView?.configuration.userContentController else { return }
        c.removeAllScriptMessageHandlers()
        let proxy = WeakScriptHandler(self)
        c.add(proxy, contentWorld: InjectedScripts.world, name: "anglStatus")
        if Passwords.shared.enabled {
            c.add(Passwords.shared, contentWorld: Passwords.world, name: Passwords.handlerName)
        }
        c.add(proxy, contentWorld: .page, name: "anglPasskey")
        if browser.settings.twitch.emotes {
            c.addScriptMessageHandler(TwitchEmoteBridge(), contentWorld: WKContentWorld.world(name: "angl-twitch"), name: "anglTwitchEmotes")
        }
        if isInternal { c.addScriptMessageHandler(PageBridge.shared, contentWorld: .page, name: PageBridge.name) }
    }

    /// Install block lists, scripts and handlers for the page about to load. Cheap when unchanged.
    private func applyPolicy(for url: URL) -> SitePolicy {
        let p = browser.policy(for: url)
        policy = p
        guard let c = webView?.configuration.userContentController else { return p }
        let isInternal = url.scheme == InternalPages.scheme
        let twitch = browser.settings.twitch
        let advancedEnabled = browser.settings.blocking.advanced && p.blocker
        let nightAudio = browser.settings.content.nightAudio
        let key = "\(url.absoluteString)|\(p)|\(advancedEnabled)|\(scriptMuted)|\(nightAudio)|\(twitch.emotes)|\(twitch.bttv)|\(twitch.ffz)|\(twitch.seventv)|\(twitch.animated)|\(browser.web.blocker.lists.count)|\(browser.web.blocker.manifest?.generated.timeIntervalSince1970 ?? 0)|\(browser.web.scripts.generation)"
        if key != appliedKey {
            appliedKey = key
            nightAudioInstalled = nightAudio
            browser.web.blocker.apply(p, to: c)
            browser.web.scripts.install(p, url: url, muted: scriptMuted, nightAudio: nightAudio, twitchEmotes: twitch.emotes, advancedEntries: browser.web.blocker.advancedEntries(for: url, enabled: advancedEnabled), on: c)
            installHandlers(isInternal: isInternal)
        }
        return p
    }

    /// Policy inputs changed (settings, block lists): next navigation re-applies.
    func invalidatePolicy() {
        let hadNightAudio = nightAudioInstalled
        appliedKey = nil
        if let u = webView?.url { _ = applyPolicy(for: u) }
        // Switching Night audio off takes effect in the open page too, without a reload.
        if hadNightAudio, !nightAudioInstalled {
            for frame in [nil] + mediaFrames.values.map(\.info).filter({ !$0.isMainFrame }) {
                webView?.evaluateJavaScript("dispatchEvent(new Event('anglnightaudiooff'))", in: frame, in: .page) { _ in }
            }
        }
    }

    func toggleMute() {
        muted.toggle()
        applyVolume()
        owner.tabChanged(self)
    }

    func applyVolume() {
        guard webView != nil else { return }
        applyNativeMute()
        sendVolume(to: nil)
        for frame in mediaFrames.values where !frame.info.isMainFrame { sendVolume(to: frame.info) }
        appliedKey = nil
    }

    /// Updates volume.js in one frame (nil = main); iframes are reached through their media reports.
    private func sendVolume(to frame: WKFrameInfo?) {
        let f = InjectedScripts.volumeFactor(policy?.volumeDB ?? 0)
        webView?.evaluateJavaScript("window.__anglVolume && window.__anglVolume.set(\(f), \(scriptMuted))", in: frame,
                                    in: InjectedScripts.world) { _ in }
    }

    func showInspector() {
        guard let wv = webView else { return }
        wv.isInspectable = true
        // No public API opens the inspector; _inspector.show is what Safari's menu item calls.
        if wv.responds(to: NSSelectorFromString("_inspector")),
           let inspector = wv.value(forKey: "_inspector") as? NSObject,
           inspector.responds(to: NSSelectorFromString("show")) {
            inspector.perform(NSSelectorFromString("show"))
        }
    }

    // MARK: Messages from injected scripts

    fileprivate func handle(_ message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        switch message.name {
        case "anglStatus":
            let href = (body["href"] as? String).flatMap(URL.init(string:))
            switch body["type"] as? String {
            case "context": contextLink = href
            case "media":
                guard let frame = body["frame"] as? String else { break }
                let playing = body["playing"] as? Bool == true
                let wasPlaying = isPlaying
                if body["gone"] as? Bool == true {
                    mediaFrames[frame] = nil
                } else {
                    mediaFrames[frame] = (message.frameInfo, playing)
                    // An iframe may have missed volume or fallback-mute changes made before it played.
                    if playing, !message.frameInfo.isMainFrame { sendVolume(to: message.frameInfo) }
                }
                if isPlaying != wasPlaying { owner.tabChanged(self) }
            default: owner.showHover(href, from: self)
            }
        case "anglPasskey":
            if message.frameInfo.isMainFrame { owner.passkeyFailed(in: self) }
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url else { return (.cancel, preferences) }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        let web = url.scheme == "http" || url.scheme == "https"

        if action.shouldPerformDownload { return (.download, preferences) }
        if action.navigationType == .linkActivated {
            let middle = action.buttonNumber == 2 || action.buttonNumber == 4
            let flags = action.modifierFlags
            if flags.contains(.option) && !flags.contains(.command) { return (.download, preferences) }
            if flags.contains(.command) || middle {
                owner.openChild(of: self, url: url, configuration: nil, activate: flags.contains(.shift))
                return (.cancel, preferences)
            }
        }
        guard mainFrame else { return (.allow, preferences) }

        if !web, url.scheme != InternalPages.scheme, url.scheme != "about", url.scheme != "file",
           url.scheme != "data", url.scheme != "blob" {
            // mailto:, zoommtg:, … go to their apps.
            if action.navigationType == .linkActivated || action.navigationType == .other {
                NSWorkspace.shared.open(url)
            }
            return (.cancel, preferences)
        }
        let get = (action.request.httpMethod ?? "GET") == "GET"
        if web, get {
            if let rule = Engine.rule(for: url, in: browser.settings.engines.rules), let engine = Engine.engine(id: rule.engine),
               Handoff.appURL(for: engine) != nil {
                _ = await Handoff.open(url, in: engine)
                owner.toast("opened in \(engine.name)", color: browser.style.secondary)
                if webView.backForwardList.currentItem == nil { owner.close(self, subtree: false) }
                return (.cancel, preferences)
            }
            if let ws = owner.workspaceClaiming(url, from: self) {
                owner.reopen(url, in: ws, from: self)
                return (.cancel, preferences)
            }
            if browser.settings.privacy.cleanURLs {
                let clean = CleanURL.clean(url)
                if clean != url {
                    webView.load(URLRequest(url: clean))
                    return (.cancel, preferences)
                }
            }
        }
        let p = applyPolicy(for: url)
        preferences.allowsContentJavaScript = p.javascript
        if #available(macOS 26.4, *) {
            preferences.securityRestrictionMode = switch p.hardening {
            case .off: .none
            case .noJIT: .maximizeCompatibility
            case .lockdown: .lockdown
            }
        } else {
            preferences.isLockdownModeEnabled = p.hardening == .lockdown
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = response.response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"), cd.lowercased().hasPrefix("attachment") {
            return .download
        }
        return response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        browser.downloads.adopt(download)
        closeIfDownloadOnly(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        browser.downloads.adopt(download)
        closeIfDownloadOnly(webView)
    }

    /// A tab whose very first navigation became a download has nothing to show: close it.
    private func closeIfDownloadOnly(_ wv: WKWebView) {
        guard wv.backForwardList.currentItem == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.webView === wv else { return }
            self.owner.close(self, subtree: false)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The old document's frames are gone; the new one's report again once their media plays.
        let wasPlaying = isPlaying
        mediaFrames = [:]
        if isPlaying != wasPlaying { owner.tabChanged(self) }
        if let p = policy { webView.pageZoom = p.zoom }
        // New host: show its stored icon (or none) until the page's own icon loads.
        if webView.url?.host() != iconHost {
            iconHost = webView.url?.host()
            favicon = Tab.storedFavicon(for: webView.url)
        }
        Passwords.shared.pageHidden(in: self)
        owner.tabChanged(self)
        owner.navigationCommitted(in: self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let u = webView.url else { return }
        browser.history?.record(url: u, title: webView.title, typed: false)
        browser.markSessionDirty()
        loadFavicon()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        showError(error, in: webView)
    }

    private func showError(_ error: any Error, in webView: WKWebView) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return } // policy change / plug-in
        let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? node.url
        let s = browser.style.theme.color
        let html = """
        <!doctype html><meta charset="utf-8"><title>can't open page</title>
        <style>body{background:\(s.bg.base);color:\(s.fg.primary);font:13px ui-monospace,monospace;padding:12vh 10vw}
        h1{font-size:15px;font-weight:normal;color:\(s.danger)}p{color:\(s.fg.secondary)}</style>
        <h1>\(escape(e.localizedDescription))</h1><p>\(escape(failing?.absoluteString ?? ""))</p>
        """
        webView.loadHTMLString(html, baseURL: failing)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              challenge.previousFailureCount < 3, let window = owner.window else {
            return (.performDefaultHandling, nil)
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(challenge.protectionSpace.host)"
        alert.informativeText = challenge.protectionSpace.realm ?? ""
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 22))
        user.placeholderString = "user"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        pass.placeholderString = "password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
        box.addSubview(user)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession))
    }

    /// When this tab last reloaded itself after a WebContent crash.
    private var crashReloadedAt = Date.distantPast

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        mediaFrames = [:]
        playingAudio = false
        owner.tabChanged(self)
        guard owner.active === self else { unload(); return }
        // Reload once; a page that dies again right away stays down until the user reloads it,
        // so a crash loop can't keep spawning WebContent processes.
        if Date().timeIntervalSince(crashReloadedAt) > 10 {
            crashReloadedAt = Date()
            webView.reload()
        } else {
            owner.toast("page crashed (⌘R reloads)", color: owner.style.muted)
        }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let child = owner.openChild(of: self, url: nil, configuration: configuration, activate: true)
        return child.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner.close(self, subtree: false)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await panel(message, frame: frame, buttons: ["OK"])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await panel(message, frame: frame, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = defaultText ?? ""
        let r = await panel(prompt, frame: frame, buttons: ["OK", "Cancel"], accessory: field)
        return r == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func panel(_ text: String, frame: WKFrameInfo, buttons: [String], accessory: NSView? = nil) async
        -> NSApplication.ModalResponse {
        if owner.active !== self { owner.activate(self) }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : frame.securityOrigin.host
        alert.informativeText = text
        for b in buttons { alert.addButton(withTitle: b) }
        alert.accessoryView = accessory
        if let accessory { alert.window.initialFirstResponder = accessory }
        guard let window = owner.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = owner.window else { return panel.runModal() == .OK ? panel.urls : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let host = origin.host
        guard let site = URL(string: "\(origin.protocol)://\(host)") else { return .deny }
        let p = browser.policy(for: site)
        let wantsCamera = type == .camera || type == .cameraAndMicrophone
        let wantsMic = type == .microphone || type == .cameraAndMicrophone
        let known: [Bool?] = [wantsCamera ? p.camera : nil, wantsMic ? p.microphone : nil].filter { $0 != nil }
        if !known.isEmpty, known.count == [wantsCamera, wantsMic].filter({ $0 }).count {
            return known.allSatisfy { $0 == true } ? .grant : .deny
        }
        let what = type == .camera ? "camera" : type == .microphone ? "microphone" : "camera and microphone"
        let answer = await owner.askPermission(for: self, text: "\(host) wants to use your \(what)")
        if answer.remember {
            browser.updateSite(site) { o in
                if wantsCamera { o.camera = answer.allow }
                if wantsMic { o.microphone = answer.allow }
            }
        }
        return answer.allow ? .grant : .deny
    }

    // MARK: Favicons

    /// Icon URL -> icon, so a site's pages don't refetch it. Only the 32x32 bitmaps live here,
    /// never the downloaded originals (touch icons, SVGs).
    private static var faviconCache: [String: NSImage] = [:]
    /// Per-host icons, memory over `Paths.faviconsDir`; a nil value marks a known miss.
    private static var hostIcons: [String: NSImage?] = [:]

    static func storedFavicon(for url: URL?) -> NSImage? {
        guard let url, url.scheme == "http" || url.scheme == "https", let host = url.host()?.lowercased() else { return nil }
        if let hit = hostIcons[host] { return hit }
        let file = Browser.shared.paths.faviconsDir.appendingPathComponent(host + ".png")
        let img = (try? Data(contentsOf: file)).flatMap(NSImage.init(data:))
        img?.size = NSSize(width: 16, height: 16)
        hostIcons[host] = img
        return img
    }

    /// Shrinks a downloaded icon to the 32x32 bitmap kept in memory and on disk.
    private static func storeFavicon(_ img: NSImage, for url: URL) -> NSImage? {
        guard let host = url.host()?.lowercased(),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: NSSize(width: 16, height: 16))
        small.addRepresentation(rep)
        hostIcons[host] = small
        if let png = rep.representation(using: .png, properties: [:]) {
            let dir = Browser.shared.paths.faviconsDir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? png.write(to: dir.appendingPathComponent(host + ".png"), options: .atomic)
        }
        return small
    }

    /// "Clear all history" also forgets which hosts we have icons for.
    static func forgetFavicons() {
        hostIcons.removeAll()
        faviconCache.removeAll()
        try? FileManager.default.removeItem(at: Browser.shared.paths.faviconsDir)
    }

    private static let faviconSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }()

    private func loadFavicon() {
        guard let wv = webView, let page = wv.url, page.scheme == "http" || page.scheme == "https",
              container.proxy == nil else { return } // never fetch around a container's proxy
        let js = """
        const l = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')];
        const best = l.find(x => /svg/.test(x.type || x.href)) || l.find(x => /32|48|64|96|180/.test(x.sizes && x.sizes.value || '')) || l[0];
        return best ? best.href : location.origin + '/favicon.ico';
        """
        Task { @MainActor [weak self] in
            guard let raw = try? await wv.callAsyncJavaScript(js, contentWorld: InjectedScripts.world) as? String,
                  let iconURL = URL(string: raw), iconURL.scheme == "https" || iconURL.scheme == "http" else { return }
            if let cached = Tab.faviconCache[raw] { self?.setFavicon(cached); return }
            guard let (data, _) = try? await Tab.faviconSession.data(from: iconURL), let img = NSImage(data: data),
                  img.isValid, let small = Tab.storeFavicon(img, for: page) else { return }
            Tab.faviconCache[raw] = small
            self?.setFavicon(small)
        }
    }

    private func setFavicon(_ img: NSImage) {
        favicon = img
        owner.tabChanged(self)
    }
}

/// Script message handlers are retained by the controller; this keeps that from retaining the tab.
@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var tab: Tab?
    init(_ tab: Tab) { self.tab = tab }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        tab?.handle(message)
    }
}

/// WKWebView with angl's context-menu changes: links open as child tabs, plus "Open in …".
@MainActor
final class AnglWebView: WKWebView {
    weak var tab: Tab?
    /// Split view: a click in a pane focuses it.
    var onPaneFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPaneFocus?()
        super.mouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = "Open Link in New Tab"
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = "Open Image in New Tab"
            case "WKMenuItemIdentifierOpenMediaInNewWindow": item.title = "Open Video in New Tab"
            case "WKMenuItemIdentifierOpenFrameInNewWindow": item.isHidden = true
            default: break
            }
        }
        guard let tab, let link = tab.contextLink, link.scheme == "http" || link.scheme == "https" else { return }
        let index = (menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" } ?? -1) + 1
        var extra: [NSMenuItem] = []
        let containers = Browser.shared.workspaces.containers
        if containers.count > 1 {
            let sub = NSMenu()
            for c in containers {
                sub.addItem(ClosureMenuItem(c.name) { [weak tab] in tab?.owner.openChild(of: tab!, url: link, containerID: c.id) })
            }
            let item = NSMenuItem(title: "Open Link in Container", action: nil, keyEquivalent: "")
            item.submenu = sub
            extra.append(item)
        }
        for engine in Handoff.installed {
            extra.append(ClosureMenuItem("Open Link in \(engine.name)") { Task { _ = await Handoff.open(link, in: engine) } })
        }
        for (i, item) in extra.enumerated() { menu.insertItem(item, at: min(index + i, menu.items.count)) }
    }
}

/// NSMenuItem that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", state: NSControl.StateValue = .off, enabled: Bool = true,
         _ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(fire) : nil, keyEquivalent: key)
        target = self
        self.state = state
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
