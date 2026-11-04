import AnglCore
import AppKit
import LocalAuthentication
import WebKit

/// WebAuthn from Bitwarden. passkey.js (page world, main frame) hands a page's
/// `navigator.credentials.create/get({publicKey})` here; the user picks and verifies in native
/// sheets and Touch ID, and the Bitwarden SDK (bitwarden/src/lib.rs `fido2`) checks the RP ID
/// against the frame's origin and signs. The origin is WebKit's, never the page's. Requests angl
/// doesn't serve (Bitwarden off, no passkey in the vault) go back to WebKit.
@MainActor
final class PasskeyBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = PasskeyBridge()
    static let name = "anglPasskey"

    /// One ceremony at a time: its sheets and prompts never stack.
    private var busy = false

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let passwords = Passwords.shared
        let body = message.body as? [String: Any] ?? [:]
        let op = body["op"] as? String
        if op == "available" { return replyHandler(["available": passwords.passkeysAvailable], nil) }
        let o = message.frameInfo.securityOrigin
        guard op == "create" || op == "get", passwords.passkeysAvailable, message.frameInfo.isMainFrame,
              o.protocol == "https", !o.host.isEmpty, let tab = (message.webView as? AnglWebView)?.tab,
              let request = body["request"] as? [String: Any], let pk = request["publicKey"] as? [String: Any] else {
            return replyHandler(Passkey.webkit, nil)
        }
        // WebAuthn needs the document focused: a background tab can't start a ceremony.
        guard tab.owner.active === tab, let window = tab.owner.window, window.isVisible else {
            return replyHandler(Passkey.error("NotAllowedError", "The page isn't in front."), nil)
        }
        guard !busy else { return replyHandler(Passkey.error("NotAllowedError", "Another passkey request is open."), nil) }
        busy = true
        let origin = "https://\(o.host)" + (o.port == 0 || o.port == 443 ? "" : ":\(o.port)")
        let ceremony = Passkey.Ceremony(origin: origin, host: o.host, request: request, publicKey: pk, window: window)
        Task { @MainActor in
            defer { busy = false }
            let reply = op == "create" ? await passwords.createPasskey(ceremony) : await passwords.getPasskey(ceremony)
            replyHandler(reply, nil)
        }
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
        let rpId = c.publicKey["rpId"] as? String ?? c.host
        let ids = (c.publicKey["allowCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let found: [Bitwarden.Passkey]
        do { found = try await bitwarden.passkeys(rpId: rpId, ids: ids) } catch { return failed(error, in: c) }
        guard !found.isEmpty else {
            toast("No passkey for \(rpId) in Bitwarden", in: c.window)
            return Passkey.webkit
        }
        let wantsUV = c.publicKey["userVerification"] as? String != "discouraged"
        var verified = wasLocked
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
        if item.reprompt {
            guard await reprompt(in: c.window, reason: "This login asks for it before signing in.", action: "Sign In") else { return Passkey.cancelled }
            verified = true
        }
        if wantsUV, !verified {
            guard let ok = await verifyUser("sign in to \(rpId) as \(Self.label(item))") else { return Passkey.cancelled }
            verified = ok
        }
        do {
            let input: [String: Any] = ["op": "get", "origin": c.origin, "request": c.request, "cipherId": item.id, "verified": verified]
            return Passkey.credential(try await bitwarden.fido2(input, mustSave: false))
        } catch {
            return failed(error, in: c)
        }
    }

    /// `navigator.credentials.create`: a new passkey, saved to the vault (a new login, or an
    /// existing one without a passkey) before the page gets it.
    func createPasskey(_ c: Passkey.Ceremony) async -> [String: Any] {
        let wasLocked = bitwarden.state == .locked
        guard await unlockVault(in: c.window) else { return Passkey.cancelled }
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
        let logins = URL(string: c.origin + "/").flatMap { bitwarden.index?.matches(for: $0) }?.filter { !$0.hasPasskey } ?? []
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
        do {
            var input: [String: Any] = ["op": "create", "origin": c.origin, "request": c.request, "verified": verified]
            if let chosen { input["cipherId"] = chosen.id }
            let credential = try await bitwarden.fido2(input, mustSave: true)
            toast("Passkey saved to Bitwarden", in: c.window, color: Browser.shared.style.accent)
            return Passkey.credential(credential)
        } catch {
            return failed(error, in: c)
        }
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
            toast(String(error.localizedDescription.prefix(120)), in: c.window, color: Browser.shared.style.warn)
        }
        return reply
    }

    private static func label(_ p: Bitwarden.Passkey) -> String {
        p.name.isEmpty || p.name == p.userName ? p.userName : p.userName.isEmpty ? p.name : "\(p.userName) (\(p.name))"
    }
}
