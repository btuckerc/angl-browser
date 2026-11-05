import AnglCore
import AppKit
import LocalAuthentication
import WebKit

/// WebAuthn from Bitwarden. passkey.js (page world, main frame) hands a page's
/// `navigator.credentials.create/get({publicKey})` here; the user picks and verifies in native
/// sheets and Touch ID, and the Bitwarden SDK (bitwarden/src/lib.rs `fido2`) checks the RP ID
/// against the frame's origin and signs. The origin is WebKit's, never the page's. Requests angl
/// doesn't serve (Bitwarden off, no passkey in the vault) go back to WebKit. A conditional `get`
/// (passkey autofill) waits here, one per tab, until the user picks one of its passkeys in the
/// login picker, the page aborts it, the tab's document goes away, or the unlocked vault turns
/// out to hold none for it (then WebKit takes it).
@MainActor
final class PasskeyBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = PasskeyBridge()
    static let name = "anglPasskey"

    /// One ceremony at a time: its sheets and prompts never stack.
    private var busy = false
    /// Waiting conditional requests, at most one per tab.
    private var conditionals: [Conditional] = []

    /// A page's waiting passkey-autofill request. `passkeys` are read from the vault on demand
    /// (`loaded` = the vault revision they were read under; `lookup` = the read in flight, cleared
    /// when the vault changes so only the newest read lands).
    final class Conditional {
        let id: String
        weak var tab: Tab?
        let origin: String
        let host: String
        let request: [String: Any]
        let publicKey: [String: Any]
        let reply: @MainActor @Sendable (Any?, String?) -> Void
        var passkeys: [Bitwarden.Passkey] = []
        var loaded: UInt64?
        var lookup: UUID?

        init(id: String, tab: Tab, origin: String, host: String, request: [String: Any], publicKey: [String: Any],
             reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            self.id = id; self.tab = tab; self.origin = origin; self.host = host
            self.request = request; self.publicKey = publicKey; self.reply = reply
        }

        var rpId: String { publicKey["rpId"] as? String ?? host }
        var allowed: [String] { (publicKey["allowCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let passwords = Passwords.shared
        let body = message.body as? [String: Any] ?? [:]
        let op = body["op"] as? String
        if op == "available" { return replyHandler(["available": passwords.passkeysAvailable], nil) }
        let tab = (message.webView as? AnglWebView)?.tab
        if op == "abort" {
            if let tab, message.frameInfo.isMainFrame, let c = conditional(in: tab), c.id == body["id"] as? String {
                end(c, Passkey.error("AbortError", "The operation was aborted."))
                passwords.passkeysChanged(in: tab)
            }
            return replyHandler(nil, nil)
        }
        let o = message.frameInfo.securityOrigin
        guard op == "create" || op == "get" || op == "conditional", passwords.passkeysAvailable, message.frameInfo.isMainFrame,
              o.protocol == "https", !o.host.isEmpty, let tab,
              let request = body["request"] as? [String: Any], let pk = request["publicKey"] as? [String: Any] else {
            return replyHandler(Passkey.webkit, nil)
        }
        let origin = "https://\(o.host)" + (o.port == 0 || o.port == 443 ? "" : ":\(o.port)")
        if op == "conditional" {
            guard let id = body["id"] as? String else { return replyHandler(Passkey.webkit, nil) }
            // A newer request from the page replaces its last one; closed tabs' requests are dropped.
            for old in conditionals where old.tab == nil || old.tab === tab { end(old, Passkey.cancelled) }
            let c = Conditional(id: id, tab: tab, origin: origin, host: o.host, request: request, publicKey: pk, reply: replyHandler)
            conditionals.append(c)
            load(c)
            return passwords.passkeysChanged(in: tab)
        }
        // WebAuthn needs the document focused: a background tab can't start a ceremony.
        guard tab.owner.active === tab, let window = tab.owner.window, window.isVisible else {
            return replyHandler(Passkey.error("NotAllowedError", "The page isn't in front."), nil)
        }
        guard !busy else { return replyHandler(Passkey.error("NotAllowedError", "Another passkey request is open."), nil) }
        busy = true
        let ceremony = Passkey.Ceremony(origin: origin, host: o.host, request: request, publicKey: pk, window: window)
        Task { @MainActor in
            defer { busy = false }
            let reply = op == "create" ? await passwords.createPasskey(ceremony) : await passwords.getPasskey(ceremony)
            replyHandler(reply, nil)
        }
    }

    /// The tab's waiting passkey-autofill request.
    func conditional(in tab: Tab) -> Conditional? { conditionals.first { $0.tab === tab } }

    /// Still waiting: not answered, aborted, replaced or dropped with its document.
    private func waiting(_ c: Conditional) -> Bool { conditionals.contains { $0 === c } }

    /// The tab's document went away (navigation, unload): its request ends.
    func documentGone(in tab: Tab) {
        if let c = conditional(in: tab) { end(c, Passkey.cancelled) }
    }

    /// The vault changed (sync, lock, unlock, logout) or Bitwarden was turned off: passkeys are
    /// read again, and requests Bitwarden can no longer serve go back to WebKit.
    func vaultChanged() {
        guard Passwords.shared.passkeysAvailable else {
            for c in conditionals { end(c, Passkey.webkit) }
            return
        }
        for c in conditionals {
            c.loaded = nil
            c.lookup = nil
            load(c)
        }
    }

    /// Reads the request's passkeys from the unlocked vault, once per vault state; a locked vault
    /// waits for its unlock. None there: the request goes back to WebKit.
    func load(_ c: Conditional) {
        let bitwarden = Passwords.shared.bitwarden
        // Mid-sync (no settled revision) the index's publication calls vaultChanged, which loads.
        guard let revision = bitwarden.settledRevision, bitwarden.state == .unlocked, c.loaded != revision,
              c.lookup == nil, waiting(c) else { return }
        let lookup = UUID()
        c.lookup = lookup
        Task { @MainActor in
            defer { if c.lookup == lookup { c.lookup = nil } }
            let found = try? await bitwarden.passkeys(rpId: c.rpId, ids: c.allowed)
            // A vault change meanwhile started a newer lookup (or wants one): this answer is stale.
            guard let found, c.lookup == lookup, revision == bitwarden.settledRevision, waiting(c) else { return }
            c.passkeys = found
            c.loaded = revision
            if found.isEmpty { end(c, Passkey.webkit) }
            if let tab = c.tab { Passwords.shared.passkeysChanged(in: tab) }
        }
    }

    /// Answers the page once; a request that already ended stays ended.
    private func end(_ c: Conditional, _ reply: [String: Any]) {
        guard let i = conditionals.firstIndex(where: { $0 === c }) else { return }
        conditionals.remove(at: i)
        c.reply(reply, nil)
    }

    /// The user picked `passkey` for request `c` in the login picker: verify and sign. Only that
    /// request is signed, with the passkey as the vault has it now, and only while both stay put:
    /// the page may abort or replace the request, or navigate, and a sync may change the login
    /// (say, to ask for the master password), while Touch ID is up. Cancelling the verification
    /// leaves the request waiting.
    func sign(with passkey: Bitwarden.Passkey, for c: Conditional) async {
        let bitwarden = Passwords.shared.bitwarden
        guard let revision = bitwarden.settledRevision, waiting(c), c.loaded == revision,
              let item = c.passkeys.first(where: { $0.id == passkey.id }),
              let tab = c.tab, let window = tab.owner.window, tab.owner.active === tab, !busy else { return }
        busy = true
        defer { busy = false }
        let ceremony = Passkey.Ceremony(origin: c.origin, host: c.host, request: c.request, publicKey: c.publicKey, window: window)
        let current = { [weak self] in self?.waiting(c) == true && bitwarden.settledRevision == revision }
        guard let reply = await Passwords.shared.signIn(ceremony, with: item, while: current) else { return }
        end(c, reply)
    }
}

/// Replies passkey.js understands.
@MainActor
enum Passkey {
    struct Ceremony {
        let origin: String
        let host: String
        /// `{publicKey: …}` as passkey.js serialized it (byte fields base64url).
        let request: [String: Any]
        let publicKey: [String: Any]
        let window: NSWindow
    }

    static let webkit: [String: Any] = ["kind": "webkit"]

    static func credential(_ c: [String: Any]) -> [String: Any] { ["kind": "credential", "credential": c] }

    static func error(_ name: String, _ message: String) -> [String: Any] { ["kind": "error", "name": name, "message": message] }

    static let cancelled = error("NotAllowedError", "The operation either timed out or was not allowed.")

    /// The SDK's error kinds (lib.rs `webauthn_fail`) as the DOMExceptions WebAuthn specifies.
    static func error(for error: Error) -> [String: Any] {
        let failure = error as? Bitwarden.Failure
        let name = switch failure?.kind ?? "" {
        case "excluded": "InvalidStateError"
        case "security": "SecurityError"
        case "notSupported": "NotSupportedError"
        case "syntax": "SyntaxError"
        default: "NotAllowedError"
        }
        return Self.error(name, failure?.message ?? error.localizedDescription)
    }
}

extension Passwords {
    /// Bitwarden can answer WebAuthn: on and logged in (a locked vault unlocks on request).
    var passkeysAvailable: Bool { useBitwarden && bitwarden.state != .loggedOut }

    /// `navigator.credentials.get`: one of the vault's passkeys for the RP signs the challenge.
    func getPasskey(_ c: Passkey.Ceremony) async -> [String: Any] {
        let wasLocked = bitwarden.state == .locked
        guard await unlockVault(in: c.window) else { return Passkey.cancelled }
        // Read and sign under one vault state: a sync meanwhile may change the login (say, to ask
        // for the master password), and the page then asks again. An unlock just started one.
        await bitwarden.synced()
        guard let revision = bitwarden.settledRevision else { return vaultMoved(in: c) }
        let rpId = c.publicKey["rpId"] as? String ?? c.host
        let ids = (c.publicKey["allowCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let found: [Bitwarden.Passkey]
        do { found = try await bitwarden.passkeys(rpId: rpId, ids: ids) } catch { return failed(error, in: c) }
        guard !found.isEmpty else {
            toast("No passkey for \(rpId) in Bitwarden", in: c.window)
            return Passkey.webkit
        }
        let wantsUV = c.publicKey["userVerification"] as? String != "discouraged"
        let verified = wasLocked
        let item: Bitwarden.Passkey
        if found.count == 1, wantsUV, !verified, !found[0].reprompt, Self.canVerifyUser {
            // Touch ID naming the account is both the choice and the verification.
            item = found[0]
        } else {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: found.map(Self.label))
            let button = await Sheet.ask("Sign in with a passkey", "\(rpId) asks for a passkey from Bitwarden.",
                                         [("Passkey", popup)], buttons: ["Sign In", "Cancel"], in: c.window)
            guard button == 0 else { return Passkey.cancelled }
            item = found[max(popup.indexOfSelectedItem, 0)]
        }
        let current = { [weak self] in self?.bitwarden.settledRevision == revision }
        return await sign(c, with: item, verified: verified, while: current) ?? Passkey.cancelled
    }

    /// A passkey picked in the login picker for a waiting conditional request, signed only while
    /// `current` holds after verifying. nil = cancelled, or the request moved on.
    func signIn(_ c: Passkey.Ceremony, with item: Bitwarden.Passkey, while current: () -> Bool) async -> [String: Any]? {
        guard bitwarden.state == .unlocked else { return nil }
        return await sign(c, with: item, verified: false, while: current)
    }

    /// Bitwarden's re-prompt and the request's user verification, then the signature, delivered
    /// only while `current` holds. nil = cancelled.
    private func sign(_ c: Passkey.Ceremony, with item: Bitwarden.Passkey, verified: Bool,
                      while current: () -> Bool) async -> [String: Any]? {
        let rpId = c.publicKey["rpId"] as? String ?? c.host
        let wantsUV = c.publicKey["userVerification"] as? String != "discouraged"
        var verified = verified
        if item.reprompt {
            guard await reprompt(in: c.window, reason: "This login asks for it before signing in.", action: "Sign In") else { return nil }
            verified = true
        }
        if wantsUV, !verified {
            guard let ok = await verifyUser("sign in to \(rpId) as \(Self.label(item))") else { return nil }
            verified = ok
        }
        guard current() else { return nil }
        let reply: [String: Any]
        do {
            let input: [String: Any] = ["op": "get", "origin": c.origin, "request": c.request, "cipherId": item.id, "verified": verified]
            reply = Passkey.credential(try await bitwarden.fido2(input, mustSave: false))
        } catch {
            reply = failed(error, in: c)
        }
        // A lock, abort or navigation while signing revokes the answer.
        return current() ? reply : nil
    }

    /// `navigator.credentials.create`: a new passkey, saved to the vault (a new login, or an
    /// existing one without a passkey) before the page gets it.
    func createPasskey(_ c: Passkey.Ceremony) async -> [String: Any] {
        let wasLocked = bitwarden.state == .locked
        guard await unlockVault(in: c.window) else { return Passkey.cancelled }
        // The exclusion check, the logins offered and their re-prompt flags hold only for this
        // vault: a sync, lock or logout before the save cancels it. An unlock just started one.
        await bitwarden.synced()
        guard let revision = bitwarden.settledRevision else { return vaultMoved(in: c) }
        let rp = c.publicKey["rp"] as? [String: Any] ?? [:]
        let rpId = rp["id"] as? String ?? c.host
        let userName = (c.publicKey["user"] as? [String: Any])?["name"] as? String ?? ""
        let excluded = (c.publicKey["excludeCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        if !excluded.isEmpty {
            do {
                let held = try await bitwarden.passkeys(rpId: rpId, ids: excluded)
                if !held.isEmpty {
                    toast("Bitwarden already has a passkey for this account on \(rpId)", in: c.window)
                    return Passkey.error("InvalidStateError", "The authenticator already holds a passkey for this account.")
                }
            } catch { return failed(error, in: c) }
        }
        let logins = URL(string: c.origin + "/").flatMap { bitwarden.index?.matches(for: $0) }?.map(\.login).filter { !$0.hasPasskey } ?? []
        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["New login"] + logins.map { $0.name.isEmpty ? $0.username : "\($0.name) — \($0.username)" })
        if let same = logins.firstIndex(where: { !userName.isEmpty && $0.username == userName }) { popup.selectItem(at: same + 1) }
        let who = userName.isEmpty ? "" : " for \(userName)"
        let button = await Sheet.ask("Save a passkey in Bitwarden?", "\(rpId) wants to create a passkey\(who).",
                                     [("Save in", popup)], buttons: ["Save", "Cancel"], in: c.window)
        guard button == 0 else { return Passkey.cancelled }
        let chosen = popup.indexOfSelectedItem > 0 ? logins[popup.indexOfSelectedItem - 1] : nil
        var verified = wasLocked
        if let chosen, chosen.reprompt {
            guard await reprompt(in: c.window, reason: "This login asks for it before changing it.", action: "Save") else { return Passkey.cancelled }
            verified = true
        }
        let uv = (c.publicKey["authenticatorSelection"] as? [String: Any])?["userVerification"] as? String
        if uv != "discouraged", !verified {
            guard let ok = await verifyUser("save a passkey for \(rpId)") else { return Passkey.cancelled }
            verified = ok
        }
        guard bitwarden.settledRevision == revision else { return vaultMoved(in: c) }
        let epoch = bitwarden.epoch
        do {
            var input: [String: Any] = ["op": "create", "origin": c.origin, "request": c.request, "verified": verified]
            if let chosen { input["cipherId"] = chosen.id }
            let credential = try await bitwarden.fido2(input, mustSave: true)
            // Saved by now. A sync meanwhile is fine (the save asks for one); a lock or logout
            // keeps the passkey from the page, as for sign-in.
            guard epoch == bitwarden.epoch else {
                toast("Bitwarden locked before the site got the passkey; it's saved, but the site may not know it", in: c.window, color: { $0.warn })
                return Passkey.cancelled
            }
            toast("Passkey saved to Bitwarden", in: c.window, color: { $0.accent })
            return Passkey.credential(credential)
        } catch {
            return failed(error, in: c)
        }
    }

    /// A ceremony the vault changed under: nothing was signed or saved.
    private func vaultMoved(in c: Passkey.Ceremony) -> [String: Any] {
        toast("Bitwarden changed meanwhile: try again", in: c.window, color: { $0.warn })
        return Passkey.cancelled
    }

    private static var canVerifyUser: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    /// Touch ID or the login password. nil = cancelled; false = this Mac can't verify the user.
    private func verifyUser(_ reason: String) async -> Bool? {
        guard Self.canVerifyUser else { return false }
        do { return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) } catch { return nil }
    }

    /// Ceremony failures the user should see (a refused save, an unreachable server) toast;
    /// the page gets the DOMException.
    private func failed(_ error: Error, in c: Passkey.Ceremony) -> [String: Any] {
        let reply = Passkey.error(for: error)
        if reply["name"] as? String == "NotAllowedError" {
            toast(String(error.localizedDescription.prefix(120)), in: c.window, color: { $0.warn })
        }
        return reply
    }

    private static func label(_ p: Bitwarden.Passkey) -> String {
        p.name.isEmpty || p.name == p.userName ? p.userName : p.userName.isEmpty ? p.name : "\(p.userName) (\(p.name))"
    }
}
