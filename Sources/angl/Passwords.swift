import AnglCore
import AppKit
import LocalAuthentication
import WebKit

/// Logins for sign-in fields. passwords.js (an isolated content world) reports sign-in fields; a
/// native picker anchored under the field lists the frame origin's matches; picking one fills
/// username + password in that frame. Never submits. Sources: Bitwarden (Bitwarden.swift, the
/// official SDK in-process) and Apple Passwords (the system AutoFill picker in a native sheet).
@MainActor
final class Passwords: NSObject {
    static let shared = Passwords()
    static let world = WKContentWorld.world(name: "angl.passwords")
    static let handlerName = "anglPasswords"

    /// A sign-in field in one document of one frame.
    private struct Target {
        weak var tab: Tab?
        let frame: WKFrameInfo
        let origin: String
        let url: URL
        let field: String
        let document: String
        var anchor: NSRect
        enum Kind: String { case user, password, code }
        /// A username field narrows the logins by what's typed in it; a password field never
        /// reports its text; a one-time code field takes a login's code.
        let kind: Kind
        var filters: Bool { kind == .user }
        var query: String
        /// The username the page shows next to a password field (a password step): its logins rank first.
        let username: String?
        /// Asked for (⌘\) rather than offered on focus: Enter may also run an account action (unlock, log in).
        var explicit: Bool
        /// The field takes passkeys (autocomplete "webauthn"): the page's waiting passkey-autofill request lists them.
        var webauthn = false
        /// A code field the page marks autocomplete="one-time-code" (not just one that may be).
        var hinted = false
    }

    private(set) lazy var bitwarden: Bitwarden = {
        let paths = Browser.shared.paths
        let b = Bitwarden(dir: paths.stateDir.appendingPathComponent("bitwarden"), profile: paths.profile)
        b.onChange = { [weak self] in self?.vaultChanged() }
        return b
    }()
    /// The sealed user key ("remember unlock"), apart from the account's tokens.
    private var rememberedKey: String { Browser.shared.paths.profile + ".bitwarden.key" }
    /// A login, unlock or Touch ID flow is up; account flows never overlap.
    private var inFlow = false
    private var target: Target?
    private var picker: PasswordPicker?
    private var dismissed: [String] = []
    private var idleTimer: Timer?
    private var monitor: Any?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            _ = ws.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Passwords.shared.lock() } }
        }
        _ = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Passwords.shared.lock() }
        }
        _ = NotificationCenter.default.addObserver(forName: .anglSettings, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Passwords.shared.settingsChanged() }
        }
    }

    var settings: Settings.Passwords { Browser.shared.settings.passwords }
    var useBitwarden: Bool { settings.provider == .bitwarden }
    /// Any source on: passwords.js runs and the picker can appear.
    var enabled: Bool { useBitwarden || settings.applePasswords }

    private func settingsChanged() {
        if !useBitwarden { lock(revoke: true) }
        if !settings.rememberUnlock { forgetRemembered() }
        if picker != nil, let t = target { enabled && isCurrent(t) ? show(for: t) : closePicker() }
        resetIdleTimer()
    }

    // MARK: Page hooks

    /// ⌘\ — offer logins for the page's focused (or first) sign-in field; falls back to the last
    /// field reported in this tab (sign-ins inside frames). Again while they're up: search the vault.
    func fillFocused(in tab: Tab) {
        guard enabled else { tab.owner.toast("Passwords are off (Settings › Passwords)", color: Browser.shared.style.secondary); return }
        if let picker, let t = target, t.tab === tab, isCurrent(t) {
            if canSearch { picker.searching ? picker.focusSearch() : beginSearch() }
            return
        }
        guard let wv = tab.webView else { return }
        Task { @MainActor in
            let found = try? await wv.callAsyncJavaScript("return window.__anglPasswordsFind ? window.__anglPasswordsFind() : false",
                                                          arguments: [:], in: nil, contentWorld: Self.world)
            if found as? Bool == true { return }
            if var t = target, t.tab === tab { t.explicit = true; target = t; show(for: t) }
            else { tab.owner.toast("No sign-in field on this page", color: Browser.shared.style.secondary) }
        }
    }

    /// Drops the vault keys. Auto-locks (idle, screen lock, sleep) keep a remembered key so
    /// Touch ID can bring the vault back; `revoke` (the Lock command, turning Bitwarden off) forgets it.
    func lock(revoke: Bool = false) {
        closePicker()
        target = nil
        idleTimer?.invalidate(); idleTimer = nil
        if revoke { forgetRemembered() }
        bitwarden.lock()
        PasskeyBridge.shared.vaultChanged()
    }

    func logOut() {
        lock(revoke: true)
        do { try bitwarden.logOut() } catch { fail(error) }
        PasskeyBridge.shared.vaultChanged()
    }

    /// For Settings › Passwords.
    var status: [String: Any] {
        let state = switch bitwarden.state { case .loggedOut: "loggedOut"; case .locked: "locked"; case .unlocked: "unlocked" }
        return ["state": state, "email": bitwarden.account?.email ?? "", "server": bitwarden.account?.server ?? ""]
    }

    /// The tab stopped showing the picker's page (switched away, closed, navigated).
    func pageHidden(in tab: Tab) {
        if picker != nil, target?.tab == nil || target?.tab === tab { closePicker() }
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard enabled, let tab = (message.webView as? AnglWebView)?.tab, let wv = tab.webView,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let o = message.frameInfo.securityOrigin
        guard o.protocol == "https", !o.host.isEmpty else { return }
        let origin = "https://\(o.host)" + (o.port == 0 || o.port == 443 ? "" : ":\(o.port)")
        guard body["origin"] as? String == origin, let document = body["document"] as? String else { return }
        switch type {
        case "field":
            guard let field = body["field"] as? String, let r = body["rect"] as? [String: Double] else { return }
            let explicit = body["explicit"] as? Bool ?? false
            let focused = body["focused"] as? Bool ?? false
            if !explicit, !settings.suggestOnFocus { return }
            if !explicit, !focused, dismissed.contains(document) { return }
            guard tab.owner.active === tab, tab.owner.window?.isVisible == true else { return }
            let frameURL = message.frameInfo.request.url
            let url = frameURL?.host() == o.host ? frameURL! : URL(string: origin + "/")!
            let anchor = anchorRect(r, exact: body["exact"] as? Bool ?? false, in: wv)
            let username = (body["username"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let t = Target(tab: tab, frame: message.frameInfo, origin: origin, url: url, field: field, document: document, anchor: anchor,
                           kind: (body["kind"] as? String).flatMap(Target.Kind.init) ?? .user, query: body["query"] as? String ?? "",
                           username: username, explicit: explicit, webauthn: body["webauthn"] as? Bool ?? false,
                           hinted: body["hinted"] as? Bool ?? false)
            // Same field, picker up: follow it (scroll, resize), unless it now takes passkeys or codes.
            if let cur = target, cur.field == field, cur.document == document, cur.webauthn == t.webauthn, cur.kind == t.kind, picker != nil {
                target = t
                picker?.anchor(below: anchor)
                return
            }
            target = t
            show(for: t)
        case "dismiss":
            guard target?.document == document else { return }
            if body["remember"] as? Bool == true { dismissed.append(document); if dismissed.count > 64 { dismissed.removeFirst() } }
            closePicker()
        case "query":
            guard var t = target, picker != nil, t.document == document, t.filters, t.field == body["field"] as? String else { return }
            t.query = body["query"] as? String ?? ""
            target = t
            show(for: t)
        case "key":
            guard target?.document == document, let picker, !picker.searching, let key = body["key"] as? String else { return }
            switch key {
            case "ArrowDown": picker.move(1)
            case "ArrowUp": picker.move(-1)
            case "Enter": picker.activate()
            default: dismissed.append(document); closePicker()
            }
        default: break
        }
    }

    // MARK: Picker

    /// The vault is open: the picker can search all of it.
    private var canSearch: Bool { useBitwarden && bitwarden.state == .unlocked }

    /// `keep`: a refresh of the same list (a sync, a re-anchor) keeps the selected row; otherwise
    /// the selection starts over (armed only on a passkey or a login for this very site, or an
    /// asked-for action).
    private func show(for t: Target, keep: Bool = false) {
        resetIdleTimer()
        if let picker, picker.searching { return refreshSearch(picker) }
        if t.kind == .code { return showCodes(for: t, keep: keep) }
        var rows: [Row] = [], footer: [Row] = []
        var arm = false, search = false
        if useBitwarden {
            switch bitwarden.state {
            case .loggedOut, .locked:
                rows = accountRows
                arm = t.explicit
            case .unlocked:
                bitwarden.refresh()
                let q = t.query.trimmingCharacters(in: .whitespacesAndNewlines)
                func narrowed(_ name: String, _ username: String) -> Bool {
                    q.isEmpty || username.localizedCaseInsensitiveContains(q) || name.localizedCaseInsensitiveContains(q)
                }
                let found = pageMatches(for: t), request = pagePasskeys(for: t), keys = request?.passkeys ?? []
                var shown = found.filter { narrowed($0.login.name, $0.login.username) }
                var shownKeys = keys.filter { narrowed($0.name, $0.userName) }
                if shown.isEmpty, shownKeys.isEmpty, !q.isEmpty {
                    // Typed past every login: get out of the way (↩ submits the form, not a picker row).
                    if picker != nil { return closePicker() }
                    shown = found; shownKeys = keys
                }
                if shown.isEmpty, shownKeys.isEmpty {
                    rows = [.note("No logins saved for \(Self.display(t.url))")]
                    // ⌘\ on a site with nothing saved: straight to search.
                    search = t.explicit
                } else {
                    if !shownKeys.isEmpty, !shown.isEmpty { rows.append(.header("Passkeys")) }
                    if let request { rows += shownKeys.map { .passkey($0, request) } }
                    rows += Self.sections(shown, page: t.url, headed: !shownKeys.isEmpty)
                    // A passkey asks for Touch ID before signing; a password goes into the page, so
                    // only this site's own is armed. Typing takes the selection away: ↩ is the page's until ↓.
                    arm = q.isEmpty && (!shownKeys.isEmpty || shown[0].tier <= .nearHost)
                }
                footer = [.search]
            }
        }
        if settings.applePasswords { footer.append(.apple) }
        present(rows, footer: footer, arm: arm, keep: keep, for: t)
        if search { beginSearch() }
    }

    /// Log in or unlock, while Bitwarden is either.
    private var accountRows: [Row] {
        switch bitwarden.state {
        case .loggedOut: [.logIn]
        case .locked: settings.rememberUnlock && SealedKey.available && Keychain.exists(rememberedKey) ? [.touchID, .unlock] : [.unlock]
        case .unlocked: []
        }
    }

    /// A one-time code field: the page's logins that have a code. Any field asking for "the code"
    /// may be one, so on focus the picker appears only with codes to offer (or, locked, for a
    /// field marked one-time-code); ⌘\ always.
    private func showCodes(for t: Target, keep: Bool) {
        guard useBitwarden else {
            if t.explicit { t.tab?.owner.toast("One-time codes come from Bitwarden (Settings › Passwords)", color: Browser.shared.style.secondary) }
            return closePicker()
        }
        var rows = accountRows, footer: [Row] = [], arm = t.explicit
        if bitwarden.state == .unlocked {
            bitwarden.refresh()
            let found = codeMatches(for: t)
            guard t.explicit || !found.isEmpty else { return closePicker() }
            if found.isEmpty {
                rows = [.note("No one-time codes saved for \(Self.display(t.url))")]
                arm = false
            } else {
                rows = Self.sections(found, page: t.url, headed: false)
                arm = found[0].tier <= .nearHost
            }
            footer = [.search]
        } else if !t.explicit, !t.hinted {
            return closePicker()
        }
        present(rows, footer: footer, arm: arm, keep: keep, for: t)
    }

    private func codeMatches(for t: Target) -> [LoginIndex.Match] {
        pageMatches(for: t).filter(\.login.hasTOTP)
    }

    /// The page's logins, best first: this site's own before other sites on its domain, then by
    /// the username the page shows, last use here, favorites.
    private func pageMatches(for t: Target) -> [LoginIndex.Match] {
        bitwarden.index?.matches(for: t.url, ranking: .init(lastUsed: bitwarden.usage.lastUsed, username: t.username)) ?? []
    }

    /// The waiting passkey-autofill request of a main-frame field that takes passkeys, when it's
    /// from the field's origin and its passkeys are read (`PasskeyBridge.load` re-shows the
    /// picker when they arrive).
    private func pagePasskeys(for t: Target) -> PasskeyBridge.Conditional? {
        guard t.webauthn, t.frame.isMainFrame, let tab = t.tab, let c = PasskeyBridge.shared.conditional(in: tab), c.origin == t.origin else { return nil }
        guard let revision = bitwarden.settledRevision, c.loaded == revision else {
            PasskeyBridge.shared.load(c)
            return nil
        }
        return c
    }

    /// A page started (or replaced) a passkey-autofill request: an open picker for it lists its passkeys.
    func passkeysChanged(in tab: Tab) {
        if picker != nil, let t = target, t.tab === tab, isCurrent(t) { show(for: t) }
    }

    /// Logins under headings: this site's own logins lead without one (unless passkeys come
    /// first); broader matches say how they match.
    private static func sections(_ matches: [LoginIndex.Match], page: URL, headed: Bool) -> [Row] {
        var rows: [Row] = []
        var current: LoginIndex.Match.Tier?
        for m in matches {
            let tier = m.tier == .nearHost ? .host : m.tier
            if tier != current {
                switch tier {
                case .host, .nearHost: if headed { rows.append(.header("Passwords")) }
                case .rule: rows.append(.header("Matched by URI rules"))
                case .domain: rows.append(.header("Other logins on \(LoginIndex.domain(of: page.host() ?? "") ?? display(page))"))
                case .equivalent: rows.append(.header("Equivalent sites"))
                }
                current = tier
            }
            rows.append(.login(Entry(login: m.login, host: m.host, showHost: m.tier != .host)))
        }
        return rows
    }

    /// host[:port] as the user reads it.
    private static func display(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// A background sync swapped the index, or the server ended the session.
    private func vaultChanged() {
        if bitwarden.state == .loggedOut { forgetRemembered() }
        PasskeyBridge.shared.vaultChanged()
        if picker != nil, let t = target, isCurrent(t) { show(for: t, keep: true) }
    }

    private func present(_ rows: [Row], footer: [Row], arm: Bool, keep: Bool, for t: Target) {
        guard let tab = t.tab, let window = tab.owner.window, isCurrent(t) else { return }
        if picker == nil {
            let p = PasswordPicker(style: Browser.shared.style)
            p.onPick = { [weak self] row in self?.picked(row) }
            p.onArm = { [weak self] armed in self?.armedChanged(armed) }
            p.onSearch = { [weak self] _ in if let self, let picker = self.picker { self.refreshSearch(picker) } }
            p.onEndSearch = { [weak self] in self?.endSearch() }
            window.addChildWindow(p, ordered: .above)
            picker = p
            installMonitor()
        }
        picker?.set(rows: rows, footer: footer, arm: arm, keep: keep, width: max(360, min(480, t.anchor.width)))
        picker?.anchor(below: t.anchor)
        picker?.orderFront(nil)
        armedChanged(picker?.armed ?? false)
    }

    /// The field passwords.js was last told the picker is up for, and whether a row is armed
    /// (↩ goes to the page unless one is).
    private var told: (target: Target, armed: Bool)?

    private func armedChanged(_ armed: Bool) {
        guard let t = target else { return }
        if let told, told.target.field == t.field, told.target.document == t.document {
            if told.armed == armed { return }
        } else if let told {
            // The picker moved to another field (maybe another frame): the old one's off.
            setShown(false, armed: false, in: told.target)
        }
        told = (t, armed)
        setShown(true, armed: armed, in: t)
    }

    private func closePicker() {
        guard let p = picker else { return }
        picker = nil
        if let told, told.target.field != target?.field || told.target.document != target?.document {
            setShown(false, armed: false, in: told.target)
        }
        told = nil
        // Hand the keyboard back before the panel goes, even with angl inactive, so the browser
        // window (not a closed panel) is key when angl comes back.
        if p.isKeyWindow { returnFocus(to: target, from: p) }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let t = target { setShown(false, armed: false, in: t) }
    }

    /// Back to the page's field after the search field had the keyboard. Works with angl inactive
    /// too: `makeKey` doesn't activate the app, it only stops the panel being key.
    private func returnFocus(to t: Target?, from p: PasswordPicker) {
        guard let window = p.parent ?? t?.tab?.owner.window else { return }
        window.makeKey()
        if let tab = t?.tab, tab.owner.active === tab, let wv = tab.webView { window.makeFirstResponder(wv) }
    }

    /// Clicks elsewhere in angl or ⌘-shortcuts (tab switches…) close the picker; in the picker's
    /// own search field they're editing, and ⌘\ (Fill Login) again opens search.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated {
                let p = Passwords.shared
                guard event.window !== p.picker else { return }
                if event.type == .keyDown, !event.modifierFlags.contains(.command) || Commands.chord("passwords.fill")?.matches(event) == true { return }
                p.closePicker()
            }
            return event
        }
    }

    private func setShown(_ shown: Bool, armed: Bool, in t: Target) {
        guard let wv = t.tab?.webView else { return }
        wv.callAsyncJavaScript("window.__anglPasswordsShown && window.__anglPasswordsShown(shown, armed)", arguments: ["shown": shown, "armed": armed],
                               in: t.frame, in: Self.world) { _ in }
    }

    // MARK: Search

    /// The picker takes the keyboard with a search field over the whole vault; the page's field
    /// stays the fill target.
    private func beginSearch() {
        guard canSearch, let picker, let t = target, isCurrent(t) else { return }
        picker.beginSearch()
        armedChanged(false)
        refreshSearch(picker)
    }

    private func refreshSearch(_ picker: PasswordPicker) {
        guard let t = target, canSearch, let index = bitwarden.index else { return closePicker() }
        let q = picker.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let codes = t.kind == .code
        let page = codes ? codeMatches(for: t) : pageMatches(for: t)
        var rows: [Row]
        if q.isEmpty {
            rows = page.isEmpty ? [.note("No \(codes ? "one-time codes" : "logins") saved for \(Self.display(t.url)) · type to search")]
                : Self.sections(page, page: t.url, headed: false)
        } else {
            let found = index.search(q, lastUsed: bitwarden.usage.lastUsed, including: { !codes || $0.hasTOTP })
            rows = found.isEmpty ? [.note("No \(codes ? "logins with a one-time code" : "logins") match “\(q)”")]
                : found.map { .login(Entry(login: $0, host: index.site(of: $0.id), showHost: true)) }
        }
        picker.set(rows: rows, footer: [], arm: true, keep: false, width: 480)
        picker.anchor(below: t.anchor)
    }

    /// Esc in the search field: back to the page's logins, keyboard back in the page.
    private func endSearch() {
        guard let picker, var t = target else { return }
        picker.endSearch()
        returnFocus(to: t, from: picker)
        // Back to the list, not into search again (⌘\ on a site with nothing saved starts there).
        t.explicit = false
        target = t
        show(for: t)
    }

    private func picked(_ row: Row) {
        if case .search = row { return beginSearch() }
        closePicker()
        guard let t = target, isCurrent(t), let window = t.tab?.owner.window else { return }
        Task { @MainActor in
            switch row {
            case .login(let e) where useBitwarden:
                await fill(e.login.id, into: t, in: window)
            case .passkey(let p, let request) where useBitwarden:
                await PasskeyBridge.shared.sign(with: p, for: request)
            case .unlock where useBitwarden: await exclusive { await unlockSheet(in: window, then: t) }
            case .touchID where useBitwarden: await exclusive { await restoreRemembered(in: window, then: t) }
            case .logIn where useBitwarden: await exclusive { await logIn(in: window, then: t) }
            case .apple where settings.applePasswords: await applePasswords(in: window, for: t)
            default: break
            }
        }
    }

    /// A login Bitwarden wouldn't offer for this frame: fill it once, after saying where it goes.
    /// Nothing is remembered and the login isn't changed.
    private func confirmElsewhere(_ login: LoginIndex.Login, saved host: String?, for t: Target, in window: NSWindow) async -> Bool {
        let saved = host.map { "is saved for \($0)" } ?? "has no website saved"
        let account = login.username.isEmpty ? "“\(login.title)”" : "“\(login.title)” (\(login.username))"
        let top = t.tab?.webView?.url.map(Self.display)
        let destination = Self.display(URL(string: t.origin + "/") ?? t.url)
        let embedded = top.flatMap { $0 == destination ? nil : " inside \($0)" } ?? ""
        let button = await Sheet.ask("Fill a login saved for another site?",
                                     "\(account) \(saved). It will be filled into \(t.origin)\(embedded).",
                                     [], buttons: ["Cancel", "Fill Once"], in: window)
        return button == 1 && isCurrent(t)
    }

    /// Runs one account flow (log in, unlock, Touch ID); a second one while it's up is ignored.
    func exclusive(_ flow: () async -> Void) async {
        guard !inFlow else { return }
        inFlow = true
        defer { inFlow = false }
        await flow()
    }

    // MARK: Fill

    /// Fills login `id` (or, into a code field, its one-time code) as the vault has it now: the
    /// row may predate a sync, so whether it matches this page (or needs Fill Once) and whether
    /// it asks for the master password are decided here, and the fill goes ahead only if the
    /// vault didn't change meanwhile.
    private func fill(_ id: String, into t: Target, in window: NSWindow) async {
        let epoch = bitwarden.epoch
        guard let revision = bitwarden.settledRevision, let index = bitwarden.index,
              let login = index.logins.first(where: { $0.id == id }) else { return vaultMoved(t) }
        do {
            if !pageMatches(for: t).contains(where: { $0.login.id == id }),
               !(await confirmElsewhere(login, saved: index.site(of: id), for: t, in: window)) { return }
            if login.reprompt, !(await reprompt(in: window)) { return }
            let c = try await bitwarden.credentials(id)
            guard revision == bitwarden.settledRevision else { return vaultMoved(t) }
            if t.kind == .code {
                guard let code = c.totp else {
                    t.tab?.owner.toast("“\(login.title)” has no one-time code", color: Browser.shared.style.warn)
                    return
                }
                guard try await put(code: code, into: t), revision == bitwarden.settledRevision else { return }
                bitwarden.recordUse(id)
                return
            }
            guard let filled = try await put(username: c.username, password: c.password, into: t),
                  revision == bitwarden.settledRevision else { return }
            bitwarden.recordUse(id)
            // The code goes with the password: an identifier-only step doesn't need it yet.
            if filled.password, let code = c.totp, settings.copyTOTP { copy(code, tab: t.tab) }
        } catch {
            guard epoch == bitwarden.epoch else { return }
            fail(error)
        }
    }

    /// A pick that the vault changed under (a sync, lock or logout): nothing was filled.
    private func vaultMoved(_ t: Target) {
        t.tab?.owner.toast("Bitwarden changed meanwhile: choose the login again", color: Browser.shared.style.warn)
    }

    /// Fills the field's form; passwords.js re-checks the document and origin first. nil = the
    /// field is gone; otherwise which of the two it filled.
    private func put(username: String, password: String, into t: Target) async throws -> (username: Bool, password: Bool)? {
        guard isCurrent(t), let wv = t.tab?.webView else { return nil }
        let result = try await wv.callAsyncJavaScript(
            "return window.__anglPasswordsFill(field, documentToken, origin, username, password)",
            arguments: ["field": t.field, "documentToken": t.document, "origin": t.origin, "username": username, "password": password],
            in: t.frame, contentWorld: Self.world)
        guard let filled = result as? [String: Any] else { t.tab?.owner.toast("The sign-in field is gone", color: Browser.shared.style.warn); return nil }
        return (filled["username"] as? Bool ?? false, filled["password"] as? Bool ?? false)
    }

    /// Fills a one-time code field (split one-digit boxes take a digit each). false = it's gone,
    /// or its boxes don't fit the code.
    private func put(code: String, into t: Target) async throws -> Bool {
        guard isCurrent(t), let wv = t.tab?.webView else { return false }
        let result = try await wv.callAsyncJavaScript(
            "return window.__anglPasswordsFillCode(field, documentToken, origin, code)",
            arguments: ["field": t.field, "documentToken": t.document, "origin": t.origin, "code": code],
            in: t.frame, contentWorld: Self.world)
        guard result as? Bool == true else { t.tab?.owner.toast("Couldn't fill the code field", color: Browser.shared.style.warn); return false }
        return true
    }

    private func copy(_ code: String, tab: Tab?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pb.declareTypes([.string, concealed, transient], owner: nil)
        pb.setString(code, forType: .string)
        pb.setData(Data(), forType: concealed)
        pb.setData(Data(), forType: transient)
        let count = pb.changeCount
        tab?.owner.toast("One-time code copied · clears in 30 s", color: Browser.shared.style.accent)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if pb.changeCount == count { pb.clearContents() }
        }
    }

    /// Bitwarden's "master password re-prompt" before using a protected login.
    func reprompt(in window: NSWindow, message: String? = nil, reason: String = "This login asks for it before filling.",
                  action: String = "Fill") async -> Bool {
        let pw = Sheet.secure(.password)
        let button = await Sheet.ask("Confirm your master password", message ?? reason,
                                     [("Master password", pw)], buttons: [action, "Cancel"], in: window)
        let password = Sheet.take(pw)
        guard button == 0, !password.isEmpty else { return false }
        do {
            guard try await bitwarden.verify(password) else {
                return await reprompt(in: window, message: "Wrong master password", reason: reason, action: action)
            }
            return true
        } catch {
            fail(error)
            return false
        }
    }

    /// The system AutoFill › Passwords picker, in a native sheet: WKWebView can't host it, the
    /// field editor of a username/password text field can. The picked login fills the page.
    private func applePasswords(in window: NSWindow, for t: Target) async {
        let user = NSTextField(), pw = Sheet.secure(.password)
        user.contentType = .username
        let button = await Sheet.ask("Apple Passwords", "Choose the login for \(t.url.host() ?? t.origin).",
                                     [("Username", user), ("Password", pw)], buttons: ["Fill", "Cancel"], in: window, focus: user) { [weak self] in
            // The username field's editor hosts the picker; without it (or the private action)
            // the sheet still takes typed or pasted logins.
            user.window?.makeFirstResponder(user)
            let action = NSSelectorFromString("_handleInsertFromPasswordsCommand:")
            if let editor = user.currentEditor(), editor.responds(to: action) {
                editor.perform(action, with: nil)
            } else {
                self?.toast("The Passwords picker isn't available here; type or paste the login", in: window, color: Browser.shared.style.warn)
            }
        }
        let username = user.stringValue, password = Sheet.take(pw)
        user.stringValue = ""
        guard button == 0, settings.applePasswords, !(username.isEmpty && password.isEmpty) else { return }
        do { _ = try await put(username: username, password: password, into: t) } catch { fail(error) }
    }

    // MARK: Unlock

    /// Unlocks a locked vault for a request that needs it (a passkey): Touch ID when a key is
    /// remembered, else the master password. Returns once the flow ends; false = still not unlocked.
    func unlockVault(in window: NSWindow) async -> Bool {
        if bitwarden.state == .locked {
            await exclusive {
                if settings.rememberUnlock, SealedKey.available, Keychain.exists(rememberedKey) {
                    await restoreRemembered(in: window, then: nil)
                } else {
                    await unlockSheet(in: window, then: nil)
                }
            }
        }
        return bitwarden.state == .unlocked
    }

    /// `epoch` is `bitwarden.epoch` from before the first sheet; a lock or logout since cancels.
    private func unlockSheet(in window: NSWindow, then t: Target?, epoch: UInt64? = nil, message: String? = nil) async {
        let epoch = epoch ?? bitwarden.epoch
        guard let email = bitwarden.account?.email else { return }
        let pw = Sheet.secure(.password)
        let button = await Sheet.ask("Unlock Bitwarden", message ?? email, [("Master password", pw)], buttons: ["Unlock", "Cancel"], in: window)
        let password = Sheet.take(pw)
        guard button == 0, !password.isEmpty, useBitwarden else { return }
        do {
            try await bitwarden.unlock(password: password, epoch: epoch)
            unlocked(then: t, remember: true)
        } catch let error as Bitwarden.Failure where error.wrongPassword {
            await unlockSheet(in: window, then: t, epoch: epoch, message: error.message)
        } catch {
            fail(error)
        }
    }

    /// `remember`: seal the user key for Touch ID, if that's on and nothing locked since.
    private func unlocked(then t: Target?, remember: Bool) {
        resetIdleTimer()
        PasskeyBridge.shared.vaultChanged()
        if remember, settings.rememberUnlock, SealedKey.available {
            let epoch = bitwarden.epoch
            Task { @MainActor in
                do {
                    let key = try await bitwarden.userKey()
                    guard epoch == bitwarden.epoch, useBitwarden, settings.rememberUnlock else { return }
                    try Keychain.write(try SealedKey.seal(Data(key.utf8)), rememberedKey)
                } catch { fail(error) }
            }
        }
        if let t, isCurrent(t) { show(for: t) }
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate(); idleTimer = nil
        let minutes = settings.lockAfterMinutes
        guard minutes > 0, bitwarden.state == .unlocked else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { _ in
            MainActor.assumeIsolated { Passwords.shared.lock() }
        }
    }

    /// Remembered unlock: the user key sealed to the Secure Enclave, opened by Touch ID (or the
    /// login password). A stale key (master password changed) falls back to the password sheet.
    private func restoreRemembered(in window: NSWindow, then t: Target?) async {
        let epoch = bitwarden.epoch
        let sealed: Data?
        do { sealed = try Keychain.read(rememberedKey) } catch { return fail(error) }
        guard let sealed else { return await unlockSheet(in: window, then: t, epoch: epoch) }
        let key: String
        do {
            key = String(decoding: try await SealedKey.open(sealed, reason: "unlock Bitwarden"), as: UTF8.self)
        } catch let error as LAError {
            // Cancelled, or Touch ID failed: keep the sealed key; failures offer the password.
            if [.userCancel, .appCancel, .systemCancel].contains(error.code) { return }
            return await unlockSheet(in: window, then: t, epoch: epoch)
        } catch {
            // Unreadable box or a lost enclave key.
            forgetRemembered()
            return await unlockSheet(in: window, then: t, epoch: epoch)
        }
        guard useBitwarden else { return }
        do {
            try await bitwarden.unlock(userKey: key, epoch: epoch)
            unlocked(then: t, remember: false)
        } catch is CancellationError {
        } catch {
            forgetRemembered()
            await unlockSheet(in: window, then: t, epoch: epoch)
        }
    }

    private func forgetRemembered() {
        do { try Keychain.delete(rememberedKey) } catch { fail(error) }
    }

    // MARK: Log in

    /// Settings › Passwords › Log in, Edit › Log In to Bitwarden…. Returns when the flow ends.
    func logIn(in window: NSWindow) async {
        guard useBitwarden else { return toast("Bitwarden is off (Settings › Passwords)", in: window) }
        await exclusive { await logIn(in: window, then: nil) }
    }

    /// The login sheets: email + master password (or an API key), then any two-step or
    /// new-device code. `epoch`: as for `unlockSheet`.
    private func logIn(in window: NSWindow, then t: Target?, epoch: UInt64? = nil, server reuse: ServerField? = nil, email: String = "",
                       message: String? = nil) async {
        let epoch = epoch ?? bitwarden.epoch
        let server = reuse ?? ServerField(settings.server), user = NSTextField(string: email), pw = Sheet.secure(.password)
        user.contentType = .username
        user.placeholderString = "you@example.com"
        let button = await Sheet.ask("Log in to Bitwarden", message ?? "Self-hosted (Vaultwarden or Bitwarden): choose Self-hosted and enter the server's address.",
                                     server.rows + [("Email", user), ("Master password", pw)],
                                     buttons: ["Log In", "Cancel", "Use API Key…"], in: window, focus: user)
        let password = Sheet.take(pw)
        guard useBitwarden else { return }
        switch button {
        case 0:
            let missing = server.value.isEmpty ? "Enter your server's address." : password.isEmpty || user.stringValue.isEmpty ? "Enter your email and master password." : nil
            if let missing { return await logIn(in: window, then: t, epoch: epoch, server: server, email: user.stringValue, message: missing) }
            toast("Logging in to Bitwarden…", in: window)
            do {
                let step = try await bitwarden.logIn(server: server.value, email: user.stringValue, password: password, epoch: epoch)
                saveServer(server.value)
                await advance(step, in: window, then: t)
            } catch is CancellationError {
            } catch {
                await logIn(in: window, then: t, epoch: epoch, server: server, email: user.stringValue, message: error.localizedDescription)
            }
        case 2: await logInWithKey(in: window, then: t, epoch: epoch, server: server)
        default: break
        }
    }

    /// Personal API key (web vault › Settings › Security › Keys): no two-step prompt, so it covers
    /// two-step methods these sheets can't show (Duo, security keys).
    private func logInWithKey(in window: NSWindow, then t: Target?, epoch: UInt64, server reuse: ServerField? = nil, message: String? = nil) async {
        let server = reuse ?? ServerField(settings.server), id = NSTextField(), secret = Sheet.secure(nil), pw = Sheet.secure(.password)
        let button = await Sheet.ask("Log in with an API key", message ?? "From the web vault: Settings › Security › Keys › View API key.",
                                     server.rows + [("client_id", id), ("client_secret", secret), ("Master password", pw)],
                                     buttons: ["Log In", "Cancel"], in: window, focus: id)
        let key = Sheet.take(secret), password = Sheet.take(pw)
        guard button == 0, useBitwarden else { return }
        guard !server.value.isEmpty, !id.stringValue.isEmpty, !key.isEmpty, !password.isEmpty else {
            return await logInWithKey(in: window, then: t, epoch: epoch, server: server, message: "Fill in every field.")
        }
        toast("Logging in to Bitwarden…", in: window)
        do {
            try await bitwarden.logIn(server: server.value, clientId: id.stringValue, clientSecret: key, password: password, epoch: epoch)
            saveServer(server.value)
            await advance(.done, in: window, then: t)
        } catch is CancellationError {
        } catch {
            await logInWithKey(in: window, then: t, epoch: epoch, server: server, message: error.localizedDescription)
        }
    }

    private func advance(_ step: Bitwarden.Step, in window: NSWindow, then t: Target?) async {
        switch step {
        case .done:
            toast("Bitwarden: \(bitwarden.account?.email ?? "logged in")", in: window, color: Browser.shared.style.accent)
            unlocked(then: t, remember: true)
        case .twoFactor(let attempt): await twoStep(attempt, in: window, then: t)
        case .newDevice(let attempt): await newDevice(attempt, in: window, then: t)
        }
    }

    private static let providers: [(id: Int, name: String)] = [(0, "Authenticator app"), (3, "YubiKey OTP"), (1, "Email")]

    private func twoStep(_ attempt: Bitwarden.Attempt, in window: NSWindow, then t: Target?, provider chosen: Int? = nil, message: String? = nil) async {
        let choices = Self.providers.filter { attempt.providers.contains($0.id) }
        guard !choices.isEmpty else {
            return await logInWithKey(in: window, then: t, epoch: attempt.epoch,
                                      message: "angl can't show this account's two-step method (Duo, security key). Use an API key.")
        }
        var message = message
        if chosen == nil, choices.map(\.id) == [1] {
            do { try await bitwarden.sendEmailCode(attempt) } catch { message = error.localizedDescription }
        }
        let popup = NSPopUpButton()
        popup.addItems(withTitles: choices.map(\.name))
        popup.selectItem(at: choices.firstIndex { $0.id == chosen } ?? 0)
        let code = NSTextField(), remember = NSButton(checkboxWithTitle: "Remember this device", target: nil, action: nil)
        code.contentType = .oneTimeCode
        let emailed = attempt.emailHint.map { "Email codes go to \($0)." } ?? ""
        var buttons = ["Continue", "Cancel"]
        if choices.contains(where: { $0.id == 1 }) { buttons.append("Send Email Code") }
        let button = await Sheet.ask("Two-step login", message ?? emailed, [("Method", popup), ("Code", code), ("", remember)],
                                     buttons: buttons, in: window, focus: code)
        let provider = choices[max(popup.indexOfSelectedItem, 0)].id
        switch button {
        case 0 where !code.stringValue.isEmpty:
            do {
                let step = try await bitwarden.continue(attempt, provider: provider, code: code.stringValue, remember: remember.state == .on)
                await advance(step, in: window, then: t)
            } catch is CancellationError {
            } catch {
                await twoStep(attempt, in: window, then: t, provider: provider, message: error.localizedDescription)
            }
        case 2:
            var sent = "Code sent. " + emailed
            do { try await bitwarden.sendEmailCode(attempt) } catch { sent = error.localizedDescription }
            await twoStep(attempt, in: window, then: t, provider: 1, message: sent)
        default: break
        }
    }

    private func newDevice(_ attempt: Bitwarden.Attempt, in window: NSWindow, then t: Target?, message: String? = nil) async {
        let code = NSTextField()
        code.contentType = .oneTimeCode
        let button = await Sheet.ask("Verify this device", message ?? "Bitwarden emailed a verification code to \(attempt.email).",
                                     [("Code", code)], buttons: ["Continue", "Cancel"], in: window, focus: code)
        guard button == 0, !code.stringValue.isEmpty else { return }
        do {
            await advance(try await bitwarden.continue(attempt, code: code.stringValue), in: window, then: t)
        } catch is CancellationError {
        } catch {
            await newDevice(attempt, in: window, then: t, message: error.localizedDescription)
        }
    }

    private func saveServer(_ server: String) {
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if s != settings.server { try? Browser.shared.setSetting(path: "passwords.server", value: s) }
    }

    // MARK: Helpers

    private func isCurrent(_ t: Target) -> Bool {
        guard let cur = target, cur.field == t.field, cur.document == t.document, let tab = t.tab else { return false }
        return tab.owner.active === tab
    }

    func fail(_ error: Error) {
        if error is CancellationError { return }
        closePicker()
        (target?.tab?.owner ?? (NSApp.keyWindow?.windowController as? BrowserWindowController))?
            .toast(String(error.localizedDescription.prefix(120)), color: Browser.shared.style.warn)
    }

    func toast(_ text: String, in window: NSWindow, color: NSColor = Browser.shared.style.secondary) {
        (window.windowController as? BrowserWindowController)?.toast(text, color: color)
    }

    /// Picker anchor in screen coordinates. `exact` = rect is relative to the top viewport
    /// (main frame, or same-origin frames that could add their offsets); otherwise fall back to
    /// the top of the web view.
    private func anchorRect(_ r: [String: Double], exact: Bool, in wv: WKWebView) -> NSRect {
        let z = wv.pageZoom * wv.magnification
        var rect: NSRect
        if exact {
            let x = (r["x"] ?? 0) * z, y = (r["y"] ?? 0) * z, w = (r["width"] ?? 0) * z, h = (r["height"] ?? 0) * z
            rect = NSRect(x: x, y: wv.isFlipped ? y : wv.bounds.height - y - h, width: w, height: h)
        } else {
            rect = NSRect(x: wv.bounds.midX - 160, y: wv.isFlipped ? 8 : wv.bounds.height - 9, width: 320, height: 1)
        }
        rect = rect.intersection(wv.bounds).isNull ? NSRect(x: wv.bounds.midX - 160, y: wv.bounds.midY, width: 320, height: 1) : rect
        guard let window = wv.window else { return .zero }
        return window.convertToScreen(wv.convert(rect, to: nil))
    }
}

extension Passwords: WKScriptMessageHandler {
    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { received(message) }
    }
}

/// A login in the picker and where it's saved. Whether it matches the frame (or fills only
/// after Fill Once) is decided when it's picked, against the vault as it is then.
private struct Entry {
    let login: LoginIndex.Login
    /// host[:port] it's saved for.
    let host: String?
    /// Say where it's saved: anything but this very host.
    let showHost: Bool
}

private enum Row {
    /// A passkey row signs only the request it was listed for.
    case login(Entry), passkey(Bitwarden.Passkey, PasskeyBridge.Conditional), header(String), note(String), search, unlock, touchID, logIn, apple

    var selectable: Bool { switch self { case .header, .note: false; default: true } }

    var height: CGFloat { switch self { case .login, .passkey: 44; case .header: 24; case .note: 34; default: 30 } }

    /// Keeps the selection on the same row across a refresh.
    var id: String {
        switch self {
        case .login(let e): "login:" + e.login.id
        case .passkey(let p, _): "passkey:" + p.id
        case .header(let t): "header:" + t
        case .note(let t): "note:" + t
        case .search: "search"
        case .unlock: "unlock"
        case .touchID: "touchID"
        case .logIn: "logIn"
        case .apple: "apple"
        }
    }

    var title: String {
        switch self {
        case .login(let e): e.login.title
        case .passkey(let p, _): p.userName.isEmpty ? p.name : p.userName
        case .header(let t), .note(let t): t
        case .search: "Search Bitwarden…"
        case .unlock: "Unlock Bitwarden…"
        case .touchID: "Unlock with Touch ID"
        case .logIn: "Log in to Bitwarden…"
        case .apple: "Apple Passwords…"
        }
    }

    /// The second line: a login's username when the title is its name; what a passkey is.
    var subtitle: String {
        switch self {
        case .login(let e): e.login.name.isEmpty ? "" : e.login.username
        case .passkey(let p, _): p.name.isEmpty || p.name == title ? "Passkey" : "Passkey · \(p.name)"
        default: ""
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .login(let e):
            var parts = [title, subtitle]
            if e.showHost, let host = e.host { parts.append(host) }
            if e.login.hasPasskey { parts.append("has a passkey") }
            if e.login.hasTOTP { parts.append("one-time code") }
            if e.login.reprompt { parts.append("asks for the master password") }
            return parts.filter { !$0.isEmpty }.joined(separator: ", ")
        case .passkey: return "\(title), \(subtitle)"
        default: return title
        }
    }
}

// MARK: - Sheets

/// Small native forms as alert sheets.
@MainActor
enum Sheet {
    /// Shows the sheet; returns the index of the button that closed it. `shown` runs once it's up.
    static func ask(_ title: String, _ info: String, _ rows: [(String, NSView)], buttons: [String], in window: NSWindow,
                    focus: NSView? = nil, shown: (() -> Void)? = nil) async -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        buttons.forEach { alert.addButton(withTitle: $0) }
        if !rows.isEmpty {
            let grid = NSGridView(views: rows.map { label, view in
                if view is NSTextField || view is NSPopUpButton { view.widthAnchor.constraint(equalToConstant: 240).isActive = true }
                return [label.isEmpty ? NSGridCell.emptyContentView : NSTextField(labelWithString: label), view]
            })
            grid.rowSpacing = 8
            grid.column(at: 0).xPlacement = .trailing
            grid.rowAlignment = .firstBaseline
            grid.layoutSubtreeIfNeeded()
            grid.frame.size = grid.fittingSize
            alert.accessoryView = grid
        }
        alert.window.initialFirstResponder = focus ?? rows.first?.1
        if let shown { Task { @MainActor in shown() } }
        let response = await alert.beginSheetModal(for: window)
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func secure(_ type: NSTextContentType?) -> NSSecureTextField {
        let f = NSSecureTextField()
        f.contentType = type
        return f
    }

    /// Reads a secret field and clears it.
    static func take(_ field: NSTextField) -> String {
        defer { field.stringValue = "" }
        return field.stringValue
    }
}

/// The server rows: Bitwarden's US or EU cloud, or a self-hosted address (Vaultwarden or
/// Bitwarden, e.g. vault.example.com) typed into the URL field it enables.
@MainActor
private final class ServerField: NSObject {
    private static let clouds = [(setting: "bitwarden.com", title: "Bitwarden.com (US)"), (setting: "bitwarden.eu", title: "Bitwarden.eu (EU)")]
    private let popup = NSPopUpButton()
    private let url = NSTextField()

    init(_ setting: String) {
        super.init()
        popup.addItems(withTitles: Self.clouds.map(\.title) + ["Self-hosted"])
        url.placeholderString = "vault.example.com"
        let s = setting.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let i = Self.clouds.firstIndex(where: { [$0.setting, "vault." + $0.setting].contains(s) }) ?? (s.isEmpty ? 0 : nil) {
            popup.selectItem(at: i)
        } else {
            popup.selectItem(at: Self.clouds.count)
            url.stringValue = setting
        }
        popup.target = self
        popup.action = #selector(changed)
        url.isEnabled = selfHosted
    }

    private var selfHosted: Bool { popup.indexOfSelectedItem == Self.clouds.count }

    @objc private func changed() {
        if selfHosted {
            url.isEnabled = true
            url.window?.makeFirstResponder(url)
        } else {
            // A field that's mid-edit stays editable when disabled; end the edit first.
            if url.currentEditor() != nil { url.window?.makeFirstResponder(popup) }
            url.isEnabled = false
        }
    }

    /// The setting to log in with; empty = self-hosted without an address yet.
    var value: String {
        selfHosted ? url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : Self.clouds[max(popup.indexOfSelectedItem, 0)].setting
    }

    var rows: [(String, NSView)] { [("Server", popup), ("Server URL", url)] }
}

// MARK: - Picker

/// A list under the sign-in field: the page's logins (scrolling past about six), then pinned
/// Search and Apple Passwords rows. Non-activating: the page keeps focus, so typing narrows a
/// username field's logins and passwords.js forwards ↑ ↓ ↩ esc. Search takes the keyboard: the
/// panel turns key with a search field over the whole vault.
@MainActor
private final class PasswordPicker: NSPanel, NSTextFieldDelegate {
    private let list: PickerList
    private let searchField = NSTextField()
    private var field = NSRect.zero
    private var width: CGFloat = 360
    var onPick: (Row) -> Void = { _ in }
    /// A row is selected (↩ picks it) or not (↩ is the page's).
    var onArm: (Bool) -> Void = { _ in }
    var onSearch: (String) -> Void = { _ in }
    var onEndSearch: () -> Void = {}
    private(set) var searching = false

    init(style: Style) {
        list = PickerList(style: style)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 32), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hasShadow = true
        isOpaque = true
        backgroundColor = style.raised
        hidesOnDeactivate = true
        contentView = list
        list.onPick = { [weak self] row in self?.onPick(row) }
        list.onArm = { [weak self] armed in self?.onArm(armed) }
        searchField.isBordered = false; searchField.drawsBackground = false; searchField.focusRingType = .none
        searchField.usesSingleLineMode = true; searchField.cell?.isScrollable = true; searchField.cell?.wraps = false
        searchField.font = style.ui; searchField.textColor = style.primary
        searchField.placeholderString = "Search Bitwarden: name, username or site"
        searchField.setAccessibilityLabel("Search Bitwarden")
        searchField.delegate = self
        searchField.isHidden = true
        list.addSubview(searchField)
        list.searchField = searchField
    }

    /// Key only while searching: otherwise the page keeps the keyboard.
    override var canBecomeKey: Bool { searching }
    override var canBecomeMain: Bool { false }

    var armed: Bool { list.armed }
    var searchText: String { searchField.stringValue }

    /// `arm`: select the first row (↩ picks it). `keep`: keep the selected row if it's still there.
    func set(rows: [Row], footer: [Row], arm: Bool, keep: Bool, width: CGFloat) {
        self.width = width
        list.set(rows: rows, footer: footer, arm: arm, keep: keep)
        place()
    }

    func anchor(below field: NSRect) {
        self.field = field
        place()
    }

    func beginSearch() {
        searching = true
        list.searching = true
        searchField.stringValue = ""
        searchField.isHidden = false
        focusSearch()
    }

    func focusSearch() {
        makeKey()
        makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func endSearch() {
        makeFirstResponder(nil)
        searching = false
        list.searching = false
        searchField.isHidden = true
        searchField.stringValue = ""
    }

    /// Below the field when it fits, else on the roomier side; the scrolling band shrinks to fit.
    private func place() {
        let screen = parent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? field.insetBy(dx: -4000, dy: -4000)
        let below = field.minY - screen.minY - 4, above = screen.maxY - field.maxY - 4
        list.room = max(below, above)
        let size = NSSize(width: width, height: list.height)
        let y = size.height <= below || below >= above ? field.minY - size.height - 4 : field.maxY + 4
        let x = min(max(field.minX, screen.minX), screen.maxX - size.width)
        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    func move(_ d: Int) { list.move(d) }
    func activate() { list.activate() }

    func controlTextDidChange(_ obj: Notification) { onSearch(searchField.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): list.move(1)
        case #selector(NSResponder.moveUp(_:)): list.move(-1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): list.activate()
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)): onEndSearch()
        default: return false
        }
        return true
    }
}

/// The picker's rows: an optional search band, the scrolling rows (wheel, trackpad, or following
/// the keyboard selection), then pinned footer rows below a hairline.
@MainActor
private final class PickerList: NSView {
    static let searchBand: CGFloat = 40
    /// The scrolling band's tallest: six logins and two headings.
    static let maxBand: CGFloat = 6 * 44 + 2 * 24
    let style: Style
    var onPick: (Row) -> Void = { _ in }
    var onArm: (Bool) -> Void = { _ in }
    weak var searchField: NSTextField?
    var searching = false { didSet { relayout(); needsLayout = true } }
    /// Height the screen leaves for the panel.
    var room: CGFloat = .greatestFiniteMagnitude { didSet { if room != oldValue { relayout() } } }

    private var rows: [Row] = []
    /// rows[..<split] scroll; rows[split...] are the pinned footer.
    private var split = 0
    /// Each scrolling row's top within the scrolled content.
    private var tops: [CGFloat] = []
    private var contentH: CGFloat = 0
    private var footerH: CGFloat = 0
    private var bandH: CGFloat = 0
    /// How far the band is scrolled, in points.
    private var offset: CGFloat = 0
    /// The keyboard's row; nil = none (↩ goes to the page).
    private var selected: Int? {
        didSet {
            guard selected != oldValue else { return }
            needsDisplay = true
            for (i, e) in axRows.enumerated() { e.setAccessibilitySelected(i == selected) }
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
            if (selected != nil) != (oldValue != nil) { onArm(selected != nil) }
        }
    }
    /// Under the mouse: highlighted, but not armed.
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    /// VoiceOver sees one element per row; kept here because AX doesn't retain them.
    private var axRows: [PressableElement] = []
    private var badges: [String: NSImage] = [:]

    var armed: Bool { selected != nil }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Logins")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func set(rows main: [Row], footer: [Row], arm: Bool, keep: Bool) {
        let kept = keep ? selected.map { rows[$0].id } : nil
        let first = (main + footer).firstIndex(where: \.selectable)
        axRows = []
        rows = main + footer
        split = main.count
        var y: CGFloat = 0
        tops = main.map { r in defer { y += r.height }; return y }
        contentH = y
        footerH = footer.reduce(0) { $0 + $1.height }
        hovered = nil
        if !keep { offset = 0 }
        if let kept { selected = rows.firstIndex { $0.id == kept } ?? (arm ? first : nil) } else { selected = keep ? nil : arm ? first : nil }
        relayout()
        rebuildAccessibility()
    }

    // MARK: Geometry

    private var bandTop: CGFloat { searching ? 2 + Self.searchBand : 1 }
    private var hairline: Bool { split > 0 && footerH > 0 }
    private var footerTop: CGFloat { bandTop + bandH + (hairline ? 1 : 0) }
    private var band: NSRect { NSRect(x: 1, y: bandTop, width: bounds.width - 2, height: bandH) }
    /// The panel's height for the current rows and room.
    var height: CGFloat { footerTop + footerH + 1 }

    private func relayout() {
        let fixed = bandTop + (hairline ? 1 : 0) + footerH + 1
        bandH = min(contentH, Self.maxBand, max(room - fixed, min(contentH, 44)))
        offset = clamp(offset)
        layoutAccessibility()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let searchField else { return }
        let font = searchField.font ?? style.ui
        let fh = ceil(font.ascender - font.descender + font.leading) + 2
        searchField.frame = NSRect(x: 36, y: 1 + ((Self.searchBand - fh) / 2).rounded(), width: bounds.width - 48, height: fh)
    }

    private func clamp(_ y: CGFloat) -> CGFloat { min(max(0, y), max(0, contentH - bandH)) }

    private func rowRect(_ i: Int) -> NSRect {
        let y = i < split ? bandTop + tops[i] - offset : footerTop + rows[split..<i].reduce(0) { $0 + $1.height }
        return NSRect(x: 1, y: y, width: bounds.width - 2, height: rows[i].height)
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        let candidates = band.contains(p) ? 0..<split : p.y >= footerTop ? split..<rows.count : 0..<0
        return candidates.first { rowRect($0).contains(p) }
    }

    private func scroll(to y: CGFloat) {
        let next = clamp(y)
        guard next != offset else { return }
        offset = next
        needsDisplay = true
        layoutAccessibility()
    }

    // MARK: Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = index(at: event).flatMap { rows[$0].selectable ? $0 : nil }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: event), rows[i].selectable else { return }
        selected = i
        activate()
    }

    override func scrollWheel(with event: NSEvent) {
        guard contentH > bandH else { return }
        scroll(to: offset - (event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 44))
        mouseMoved(with: event)
    }

    /// ↑ ↓ stop at the ends. With nothing selected, ↓ takes the first row and ↑ the last.
    func move(_ d: Int) {
        let choices = rows.indices.filter { rows[$0].selectable }
        guard !choices.isEmpty else { return }
        if let s = selected, let at = choices.firstIndex(of: s) {
            selected = choices[min(max(at + d, 0), choices.count - 1)]
        } else {
            selected = d > 0 ? choices[0] : choices[choices.count - 1]
        }
        guard let s = selected, s < split else { return }
        // Keep a heading in view with its first row, and the top (a note) with the first choice.
        let top = s == choices.first ? 0 : s > 0 && !rows[s - 1].selectable ? tops[s - 1] : tops[s]
        let bottom = tops[s] + rows[s].height
        if top < offset { scroll(to: top) } else if bottom > offset + bandH { scroll(to: bottom - bandH) }
    }

    func activate() {
        guard let s = selected, rows.indices.contains(s) else { return }
        onPick(rows[s])
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        axRows = rows.enumerated().map { index, row in
            let e = PressableElement()
            e.setAccessibilityElement(true)
            e.setAccessibilityRole(row.selectable ? .row : .staticText)
            e.setAccessibilityLabel(row.accessibilityLabel)
            e.setAccessibilityParent(self)
            e.setAccessibilitySelected(index == selected)
            if row.selectable {
                e.press = { [weak self] in
                    guard let self, self.rows.indices.contains(index) else { return false }
                    self.selected = index
                    self.activate()
                    return true
                }
            }
            return e
        }
        layoutAccessibility()
        setAccessibilityChildren(axRows)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func layoutAccessibility() {
        for (i, e) in axRows.enumerated() { e.setAccessibilityFrameInParentSpace(rowRect(i)) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutAccessibility()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        style.raised.setFill(); bounds.fill()
        style.border.setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); edge.lineWidth = 1; edge.stroke()
        if searching {
            if let glass = badge("magnifyingglass", size: 13, color: style.secondary) {
                glass.draw(in: NSRect(x: 19 - glass.size.width / 2, y: 1 + (Self.searchBand - glass.size.height) / 2,
                                      width: glass.size.width, height: glass.size.height))
            }
            style.border.setFill(); NSRect(x: 1, y: 1 + Self.searchBand, width: bounds.width - 2, height: 1).fill()
        }
        if bandH > 0 {
            NSGraphicsContext.saveGraphicsState()
            band.clip()
            for i in 0..<split where rowRect(i).intersects(band) { drawRow(i) }
            if contentH > bandH {
                // Overlay scroll indicator: always shown while there is more to scroll to.
                let h = max(bandH * bandH / contentH, 16)
                let y = band.minY + (bandH - h) * offset / (contentH - bandH)
                style.muted.setFill()
                NSBezierPath(roundedRect: NSRect(x: band.maxX - 5, y: y + 2, width: 3, height: h - 4), xRadius: 1.5, yRadius: 1.5).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if hairline { style.border.setFill(); NSRect(x: 1, y: footerTop - 1, width: bounds.width - 2, height: 1).fill() }
        for i in split..<rows.count { drawRow(i) }
    }

    /// A tinted symbol, cached per name, size and color.
    private func badge(_ name: String, size: CGFloat = 11, color: NSColor) -> NSImage? {
        let key = "\(name)|\(size)|\(color.description)"
        if let hit = badges[key] { return hit }
        guard let image = style.symbol(name, size: size)?.tinted(color) else { return nil }
        badges[key] = image
        return image
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    private func width(_ s: String, _ font: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }

    /// One line of text, truncated at `width`, top at `y`.
    private func text(_ s: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont, color: NSColor) {
        guard width > 8, !s.isEmpty else { return }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        (s as NSString).draw(in: NSRect(x: x, y: y, width: width, height: Self.lineHeight(font)),
                             withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }

    /// Right-aligned short text ending at `right`; returns where it starts.
    private func trailingText(_ s: String, right: CGFloat, midY: CGFloat, font: NSFont, color: NSColor) -> CGFloat {
        let w = width(s, font)
        text(s, x: right - w, y: midY - Self.lineHeight(font) / 2, width: w + 2, font: font, color: color)
        return right - w
    }

    private func drawRow(_ i: Int) {
        let r = rowRect(i), row = rows[i]
        if i == selected {
            style.selected.setFill(); r.fill()
            style.accent.setFill(); NSRect(x: r.minX, y: r.minY, width: 2, height: r.height).fill()
        } else if i == hovered {
            style.selected.withAlphaComponent(0.55).setFill(); r.fill()
        }
        let textX = r.minX + 36, right = r.maxX - 12
        switch row {
        case .header(let title):
            let font = style.uiSmall
            text(title, x: r.minX + 12, y: r.maxY - 5 - Self.lineHeight(font), width: r.width - 24, font: font, color: style.muted)
        case .note(let note):
            let font = style.uiSmall
            text(note, x: r.minX + 12, y: r.midY - Self.lineHeight(font) / 2, width: r.width - 24, font: font, color: style.secondary)
        case .login(let e):
            drawIcon(e, in: NSRect(x: r.minX + 8, y: r.midY - 10, width: 20, height: 20))
            let badges = [(e.login.reprompt, "lock.fill"), (e.login.hasTOTP, "timer"), (e.login.hasPasskey, "person.badge.key.fill")]
                .filter(\.0).map(\.1)
            drawLines(row, in: r, selected: i == selected, host: e.showHost ? e.host : nil, badges: badges)
        case .passkey:
            if let img = badge("person.badge.key.fill", size: 14, color: style.accent) {
                img.draw(in: NSRect(x: r.minX + 18 - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            drawLines(row, in: r, selected: i == selected, host: nil, badges: [])
        case .search, .unlock, .touchID, .logIn, .apple:
            let glyph = switch row {
            case .search: "magnifyingglass"
            case .unlock: "lock.open"
            case .touchID: "touchid"
            case .logIn: "person.crop.circle"
            default: "key"
            }
            if let img = badge(glyph, size: 13, color: style.accent) {
                img.draw(in: NSRect(x: r.minX + 18 - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            var trailing = right
            if i == selected { trailing = trailingText("↩", right: trailing, midY: r.midY, font: style.monoSmall, color: style.secondary) - 10 }
            if case .search = row, let chord = Commands.chord("passwords.fill")?.label, !chord.isEmpty {
                trailing = trailingText(chord, right: trailing, midY: r.midY, font: style.monoSmall, color: style.muted) - 10
            }
            text(row.title, x: textX, y: r.midY - Self.lineHeight(style.ui) / 2, width: trailing - textX, font: style.ui, color: style.accent)
        }
    }

    /// A login or passkey: title (and where it's saved) over subtitle (and badges).
    private func drawLines(_ row: Row, in r: NSRect, selected: Bool, host: String?, badges: [String]) {
        let textX = r.minX + 36
        var trailing = r.maxX - 12
        if selected { trailing = trailingText("↩", right: trailing, midY: r.midY, font: style.monoSmall, color: style.secondary) - 10 }
        let titleFont = style.ui, subFont = style.monoSmall
        let titleH = Self.lineHeight(titleFont), subH = Self.lineHeight(subFont)
        let subtitle = row.subtitle
        let twoLines = !subtitle.isEmpty || !badges.isEmpty
        let titleY = twoLines ? r.midY - (titleH + 2 + subH) / 2 : r.midY - titleH / 2
        let subY = titleY + titleH + 2
        var titleRight = trailing
        if let host {
            let w = min(width(host, subFont), (trailing - textX) * 0.45)
            titleRight = trailing - w
            text(host, x: titleRight, y: titleY + (titleH - subH) / 2 + 1, width: w, font: subFont, color: style.muted)
            titleRight -= 10
        }
        text(row.title, x: textX, y: titleY, width: titleRight - textX, font: titleFont, color: style.primary)
        var badgeX = trailing
        for name in badges {
            guard let img = badge(name, color: style.muted) else { continue }
            badgeX -= img.size.width
            img.draw(in: NSRect(x: badgeX, y: subY + (subH - img.size.height) / 2, width: img.size.width, height: img.size.height))
            badgeX -= 6
        }
        text(subtitle, x: textX, y: subY, width: badgeX - textX - 4, font: subFont, color: style.secondary)
    }

    /// The site's stored favicon on a tile that keeps it visible (light for dark logos, the theme's
    /// for light ones), else the login's initial.
    private func drawIcon(_ e: Entry, in rect: NSRect) {
        let host = e.host.flatMap { $0.split(separator: ":").first.map(String.init) }
        let tile = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        if let host, let icon = Tab.storedFavicon(for: URL(string: "https://" + host)) {
            (Self.isLight(icon) ? style.border : NSColor(white: 0.97, alpha: 1)).setFill()
            tile.fill()
            icon.draw(in: rect.insetBy(dx: 3, dy: 3), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        style.border.setFill(); tile.fill()
        let letter = e.login.title.first.map { String($0).uppercased() } ?? "?"
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let w = width(letter, font)
        (letter as NSString).draw(at: NSPoint(x: rect.midX - w / 2, y: rect.midY - Self.lineHeight(font) / 2),
                                  withAttributes: [.font: font, .foregroundColor: style.primary])
    }

    private static let lightIcons = NSMapTable<NSImage, NSNumber>.weakToStrongObjects()

    /// Mostly light where it's opaque (a white logo for dark pages): averaged over an 8×8 copy,
    /// once per image.
    private static func isLight(_ icon: NSImage) -> Bool {
        if let hit = lightIcons.object(forKey: icon) { return hit.boolValue }
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let light = px.withUnsafeMutableBytes { buf -> Bool in
            guard let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let ctx = CGContext(data: buf.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            var luminance = 0.0, coverage = 0.0
            for i in stride(from: 0, to: buf.count, by: 4) {
                // Premultiplied: each channel already carries its alpha.
                luminance += 0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])
                coverage += Double(buf[i + 3])
            }
            return coverage > 0 && luminance / coverage > 0.75
        }
        lightIcons.setObject(NSNumber(value: light), forKey: icon)
        return light
    }
}
