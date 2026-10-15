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
    }

    private lazy var bitwarden: Bitwarden = {
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

    private var settings: Settings.Passwords { Browser.shared.settings.passwords }
    private var useBitwarden: Bool { settings.provider == .bitwarden }
    /// Any source on: passwords.js runs and the picker can appear.
    var enabled: Bool { useBitwarden || settings.applePasswords }

    private func settingsChanged() {
        if !useBitwarden { lock(revoke: true) }
        if !settings.rememberUnlock { forgetRemembered() }
        if picker != nil, let t = target { enabled && isCurrent(t) ? show(for: t) : closePicker() }
        resetIdleTimer()
    }

    // MARK: Page hooks

    func install(on controller: WKUserContentController) {
        guard enabled, let url = Bundle.main.url(forResource: "passwords", withExtension: "js", subdirectory: "web/inject"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.world))
    }

    /// ⌘\ — offer logins for the page's focused (or first) sign-in field; falls back to the last
    /// field reported in this tab (sign-ins inside frames).
    func fillFocused(in tab: Tab) {
        guard enabled else { tab.owner.toast("Passwords are off (Settings › Passwords)", color: Browser.shared.style.secondary); return }
        guard let wv = tab.webView else { return }
        Task { @MainActor in
            let found = try? await wv.callAsyncJavaScript("return window.__anglPasswordsFind ? window.__anglPasswordsFind() : false",
                                                          arguments: [:], in: nil, contentWorld: Self.world)
            if found as? Bool == true { return }
            if let t = target, t.tab === tab { show(for: t) }
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
    }

    func logOut() {
        lock(revoke: true)
        do { try bitwarden.logOut() } catch { fail(error) }
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
            let t = Target(tab: tab, frame: message.frameInfo, origin: origin, url: url, field: field, document: document, anchor: anchor)
            if let cur = target, cur.field == field, cur.document == document, picker != nil { target = t; picker?.anchor(below: anchor); return }
            target = t
            show(for: t)
        case "dismiss":
            guard target?.document == document else { return }
            if body["remember"] as? Bool == true { dismissed.append(document); if dismissed.count > 64 { dismissed.removeFirst() } }
            closePicker()
        case "key":
            guard target?.document == document, let picker, let key = body["key"] as? String else { return }
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

    private func show(for t: Target) {
        resetIdleTimer()
        var rows: [Row] = []
        if useBitwarden {
            switch bitwarden.state {
            case .loggedOut:
                rows = [.logIn]
            case .locked:
                rows = [.unlock]
                if settings.rememberUnlock, SealedKey.available, Keychain.exists(rememberedKey) { rows.insert(.touchID, at: 0) }
            case .unlocked:
                bitwarden.refresh()
                let found = bitwarden.index?.matches(for: t.url) ?? []
                rows = found.isEmpty ? [.note("No saved logins for this site")] : found.map(Row.login)
            }
        }
        if settings.applePasswords { rows.append(.apple) }
        present(rows, for: t)
    }

    /// A background sync swapped the index, or the server ended the session.
    private func vaultChanged() {
        if bitwarden.state == .loggedOut { forgetRemembered() }
        if picker != nil, let t = target, isCurrent(t) { show(for: t) }
    }

    private func present(_ rows: [Row], for t: Target) {
        guard let tab = t.tab, let window = tab.owner.window, isCurrent(t) else { return }
        if picker == nil {
            let p = PasswordPicker(style: Browser.shared.style) { [weak self] row in self?.picked(row) }
            window.addChildWindow(p, ordered: .above)
            picker = p
            installMonitor()
            setShown(true, in: t)
        }
        picker?.set(rows: rows, width: max(280, min(440, t.anchor.width)))
        picker?.anchor(below: t.anchor)
        picker?.orderFront(nil)
    }

    private func closePicker() {
        guard let p = picker else { return }
        picker = nil
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let t = target { setShown(false, in: t) }
    }

    /// Clicks elsewhere in angl or ⌘-shortcuts (tab switches…) close the picker.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated {
                let p = Passwords.shared
                if event.type == .keyDown { if event.modifierFlags.contains(.command) { p.closePicker() } }
                else if event.window !== p.picker { p.closePicker() }
            }
            return event
        }
    }

    private func setShown(_ shown: Bool, in t: Target) {
        guard let wv = t.tab?.webView else { return }
        wv.callAsyncJavaScript("window.__anglPasswordsShown && window.__anglPasswordsShown(shown)", arguments: ["shown": shown],
                               in: t.frame, in: Self.world) { _ in }
    }

    private func picked(_ row: Row) {
        closePicker()
        guard let t = target, isCurrent(t), let window = t.tab?.owner.window else { return }
        Task { @MainActor in
            switch row {
            case .login(let login) where useBitwarden: await fill(login, into: t)
            case .unlock where useBitwarden: await exclusive { await unlockSheet(in: window, then: t) }
            case .touchID where useBitwarden: await exclusive { await restoreRemembered(in: window, then: t) }
            case .logIn where useBitwarden: await exclusive { await logIn(in: window, then: t) }
            case .apple where settings.applePasswords: await applePasswords(in: window, for: t)
            default: break
            }
        }
    }

    /// Runs one account flow (log in, unlock, Touch ID); a second one while it's up is ignored.
    private func exclusive(_ flow: () async -> Void) async {
        guard !inFlow else { return }
        inFlow = true
        defer { inFlow = false }
        await flow()
    }

    // MARK: Fill

    private func fill(_ login: LoginIndex.Login, into t: Target) async {
        let epoch = bitwarden.epoch
        do {
            if login.reprompt, let window = t.tab?.owner.window, !(await reprompt(in: window)) { return }
            let c = try await bitwarden.credentials(login.id)
            guard epoch == bitwarden.epoch else { return }
            guard try await put(username: c.username, password: c.password, into: t) else { return }
            if let code = c.totp, settings.copyTOTP { copy(code, tab: t.tab) }
        } catch {
            guard epoch == bitwarden.epoch else { return }
            fail(error)
        }
    }

    /// Fills the field's form; passwords.js re-checks the document and origin first.
    private func put(username: String, password: String, into t: Target) async throws -> Bool {
        guard isCurrent(t), let wv = t.tab?.webView else { return false }
        let result = try await wv.callAsyncJavaScript(
            "return window.__anglPasswordsFill(field, documentToken, origin, username, password)",
            arguments: ["field": t.field, "documentToken": t.document, "origin": t.origin, "username": username, "password": password],
            in: t.frame, contentWorld: Self.world)
        guard result as? Bool == true else { t.tab?.owner.toast("The sign-in field is gone", color: Browser.shared.style.warn); return false }
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

    /// Bitwarden's "master password re-prompt" before filling a protected login.
    private func reprompt(in window: NSWindow, message: String? = nil) async -> Bool {
        let pw = Sheet.secure(.password)
        let button = await Sheet.ask("Confirm your master password", message ?? "This login asks for it before filling.",
                                     [("Master password", pw)], buttons: ["Fill", "Cancel"], in: window)
        let password = Sheet.take(pw)
        guard button == 0, !password.isEmpty else { return false }
        do {
            guard try await bitwarden.verify(password) else { return await reprompt(in: window, message: "Wrong master password") }
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
    private func restoreRemembered(in window: NSWindow, then t: Target) async {
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

    private func fail(_ error: Error) {
        if error is CancellationError { return }
        closePicker()
        (target?.tab?.owner ?? (NSApp.keyWindow?.windowController as? BrowserWindowController))?
            .toast(String(error.localizedDescription.prefix(120)), color: Browser.shared.style.warn)
    }

    private func toast(_ text: String, in window: NSWindow, color: NSColor = Browser.shared.style.secondary) {
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

private enum Row {
    case login(LoginIndex.Login), unlock, touchID, logIn, apple, note(String)
    var selectable: Bool { if case .note = self { false } else { true } }

    var labels: (title: String, detail: String) {
        switch self {
        case .login(let l): (l.name.isEmpty ? l.username : l.name, l.name.isEmpty ? "" : l.username)
        case .unlock: ("Unlock Bitwarden…", "")
        case .touchID: ("Unlock with Touch ID", "")
        case .logIn: ("Log in to Bitwarden…", "")
        case .apple: ("Apple Passwords…", "")
        case .note(let text): (text, "")
        }
    }
}

// MARK: - Sheets

/// Small native forms as alert sheets.
@MainActor
private enum Sheet {
    /// Shows the sheet; returns the index of the button that closed it. `shown` runs once it's up.
    static func ask(_ title: String, _ info: String, _ rows: [(String, NSView)], buttons: [String], in window: NSWindow,
                    focus: NSView? = nil, shown: (() -> Void)? = nil) async -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        buttons.forEach { alert.addButton(withTitle: $0) }
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

/// A flat list under the sign-in field. Non-activating: the page keeps focus, so typing continues
/// and passwords.js forwards ↑ ↓ ↩ esc while the picker is up.
@MainActor
private final class PasswordPicker: NSPanel {
    private let list: PickerList

    init(style: Style, action: @escaping (Row) -> Void) {
        list = PickerList(style: style, action: action)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 30), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hasShadow = true
        isOpaque = true
        backgroundColor = style.raised
        hidesOnDeactivate = true
        contentView = list
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func set(rows: [Row], width: CGFloat) {
        list.rows = rows
        setContentSize(NSSize(width: width, height: list.height))
    }

    func anchor(below field: NSRect) {
        var origin = NSPoint(x: field.minX, y: field.minY - frame.height - 4)
        if let screen = parent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if origin.y < screen.minY { origin.y = field.maxY + 4 }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - frame.width)
        }
        setFrameOrigin(origin)
    }

    func move(_ d: Int) { list.move(d) }
    func activate() { list.activate() }
}

@MainActor
private final class PickerList: NSView {
    static let rowH: CGFloat = 30
    let style: Style
    let action: (Row) -> Void
    var rows: [Row] = [] {
        didSet { selected = rows.firstIndex(where: \.selectable) ?? -1; needsDisplay = true; rebuildAccessibility() }
    }
    private var selected = -1 {
        didSet {
            needsDisplay = true
            for (i, e) in axRows.enumerated() { e.setAccessibilitySelected(i == selected) }
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
    }
    /// VoiceOver sees one row element per drawn row; kept here because AX doesn't retain them.
    private var axRows: [NSAccessibilityElement] = []
    var height: CGFloat { CGFloat(max(rows.count, 1)) * Self.rowH + 2 }

    init(style: Style, action: @escaping (Row) -> Void) {
        self.style = style; self.action = action
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func index(at event: NSEvent) -> Int {
        Int((convert(event.locationInWindow, from: nil).y - 1) / Self.rowH)
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: event)
        if rows.indices.contains(i), rows[i].selectable { selected = i }
    }

    override func mouseDown(with event: NSEvent) {
        let i = index(at: event)
        guard rows.indices.contains(i), rows[i].selectable else { return }
        selected = i
        activate()
    }

    func move(_ d: Int) {
        let choices = rows.indices.filter { rows[$0].selectable }
        guard !choices.isEmpty else { return }
        let at = choices.firstIndex(of: selected) ?? 0
        selected = choices[(at + d + choices.count) % choices.count]
    }

    func activate() {
        guard rows.indices.contains(selected) else { return }
        action(rows[selected])
    }

    private func rebuildAccessibility() {
        axRows = rows.enumerated().map { index, row in
            let (title, detail) = row.labels
            let e = NSAccessibilityElement()
            e.setAccessibilityElement(true)
            e.setAccessibilityRole(.row)
            e.setAccessibilityLabel([title, detail].filter { !$0.isEmpty }.joined(separator: ", "))
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(rowRect(index))
            e.setAccessibilitySelected(index == selected)
            return e
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityChildren(axRows)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 1, y: 1 + CGFloat(index) * Self.rowH, width: bounds.width - 2, height: Self.rowH)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for (i, e) in axRows.enumerated() { e.setAccessibilityFrameInParentSpace(rowRect(i)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        style.raised.setFill(); bounds.fill()
        style.border.setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); edge.lineWidth = 1; edge.stroke()
        for (i, row) in rows.enumerated() {
            let r = NSRect(x: 1, y: 1 + CGFloat(i) * Self.rowH, width: bounds.width - 2, height: Self.rowH)
            if i == selected {
                style.selected.setFill(); r.fill()
                style.accent.setFill(); NSRect(x: r.minX, y: r.minY, width: 2, height: r.height).fill()
            }
            let (title, detail) = row.labels
            let color = switch row { case .login: style.primary; case .note: style.muted; default: style.accent }
            let font = style.monoSmall
            let detailAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.secondary]
            let detailW = detail.isEmpty ? 0 : min((detail as NSString).size(withAttributes: detailAttrs).width, r.width * 0.5)
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            let titleRect = NSRect(x: r.minX + 12, y: r.midY - font.pointSize * 0.65, width: r.width - 24 - (detailW > 0 ? detailW + 12 : 0), height: font.pointSize * 1.4)
            (title as NSString).draw(in: titleRect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
            if detailW > 0 {
                let dr = NSRect(x: r.maxX - 12 - detailW, y: titleRect.minY, width: detailW, height: titleRect.height)
                (detail as NSString).draw(in: dr, withAttributes: detailAttrs.merging([.paragraphStyle: para]) { $1 })
            }
        }
    }
}
