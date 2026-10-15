import AnglCore
import CBitwarden
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Native Bitwarden. Identity and sync go over URLSession; vault crypto runs in the official
/// Bitwarden SDK (bitwarden/ → CBitwarden). The vault cache is the server's own encrypted sync
/// response under the profile, so unlocking works offline; tokens live in the login keychain.
/// Keys exist only while unlocked: locking drops the SDK session, which wipes them.
@MainActor
final class Bitwarden {
    enum State { case loggedOut, locked, unlocked }

    struct Failure: LocalizedError {
        let message: String
        var wrongPassword = false
        var errorDescription: String? { message }
    }

    /// The server rejected the stored credentials; the account was logged out.
    struct SignedOut: Error {}

    struct Account: Codable {
        /// "bitwarden.com", "bitwarden.eu" or a self-hosted base URL.
        var server: String
        var email: String
        var kdf: KDF
        var revision: Double?
    }

    struct KDF: Codable, Equatable {
        var type: Int
        var iterations: Int
        var memory: Int?
        var parallelism: Int?
        var json: [String: Any] {
            ["type": type, "iterations": iterations, "memory": memory ?? NSNull(), "parallelism": parallelism ?? NSNull()]
        }
    }

    /// Kept in the login keychain, never on disk.
    struct Secrets: Codable {
        var refresh: String?
        var clientId: String?
        var clientSecret: String?
        /// Bitwarden's "remember this device" token, skipping two-step login next time, and the
        /// server + email it was issued for (sent to that identity only).
        var twoFactor: String?
        var twoFactorFor: String?
    }

    struct Credentials { let username: String; let password: String; let totp: String? }

    private(set) var account: Account?
    private(set) var index: LoginIndex?
    /// Called when a background sync swaps in a new index.
    var onChange: (() -> Void)?
    private var sdk: BitwardenSDK?
    private var access: (token: String, expires: Date)?
    /// Bumps on every lock, login and logout: async work that started under an older value
    /// (an unlock, a login, an index swap) must not commit.
    private var generation: UInt64 = 0
    /// Bumps on login and logout: tokens and the vault cache belong to one account's lifetime.
    private var accountEpoch: UInt64 = 0
    private var lastCheck: Date?
    private var checking: UUID?
    private let dir: URL
    private let keychainAccount: String

    init(dir: URL, profile: String) {
        self.dir = dir
        keychainAccount = profile + ".bitwarden"
        account = try? JSONDecoder().decode(Account.self, from: Data(contentsOf: accountFile))
    }

    var state: State { account == nil ? .loggedOut : index == nil ? .locked : .unlocked }
    private var accountFile: URL { dir.appendingPathComponent("account.json") }
    private var cacheFile: URL { dir.appendingPathComponent("sync.json") }

    /// This install's device identifier, kept across logins (Bitwarden asks to verify new devices).
    private lazy var device: String = {
        let file = self.dir.appendingPathComponent("device")
        if let id = try? String(contentsOf: file, encoding: .utf8), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }()

    /// For flows that start with a sheet: capture before showing it, pass to the unlock or login;
    /// a lock, login or logout in between cancels the commit.
    var epoch: UInt64 { generation }

    // MARK: Lock / unlock

    func lock() {
        generation &+= 1
        sdk = nil
        index = nil
        access = nil
    }

    /// Forgets the account, its vault cache and tokens. An expired session keeps the
    /// remembered-device token so logging back in skips the two-step prompt.
    func logOut(expired: Bool = false) throws {
        let saved = expired ? (try? loadSecrets()) : nil
        lock()
        accountEpoch &+= 1
        account = nil
        checking = nil
        lastCheck = nil
        var failure: Error?
        for file in [accountFile, cacheFile] where FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) } catch { failure = error }
        }
        do {
            if let token = saved?.twoFactor, let identity = saved?.twoFactorFor {
                try store(Secrets(twoFactor: token, twoFactorFor: identity))
            } else { try store(nil) }
        } catch { failure = error }
        if let failure { throw Failure(message: "Bitwarden logout incomplete: \(failure.localizedDescription)") }
    }

    func unlock(password: String, epoch: UInt64) async throws { try await open(["password": password], epoch: epoch) }
    func unlock(userKey: String, epoch: UInt64) async throws { try await open(["userKey": userKey], epoch: epoch) }

    private func open(_ unlock: [String: Any], epoch: UInt64) async throws {
        guard let account else { throw Failure(message: "Not logged in") }
        guard epoch == generation else { throw CancellationError() }
        let cache = try Data(contentsOf: cacheFile)
        let sdk = BitwardenSDK()
        let loaded = try await sdk.call("load", data: cache)
        try await sdk.call("unlock", unlock.merging(["kdf": account.kdf.json]) { a, _ in a })
        let index = try await Self.index(sdk, domains: loaded["domains"] as? [[String]] ?? [])
        guard epoch == generation else { throw CancellationError() }
        self.sdk = sdk
        self.index = index
        refresh(force: true)
    }

    /// The SDK's secret-free item list → a LoginIndex, off the main thread.
    private static func index(_ sdk: BitwardenSDK, domains: [[String]]) async throws -> LoginIndex {
        try await Task.detached(priority: .userInitiated) {
            let items = try await sdk.call("index", data: Data("{}".utf8))["items"] as? [[String: Any]] ?? []
            return LoginIndex(items.map { item in
                let login = LoginIndex.Login(id: item["id"] as? String ?? "", name: item["name"] as? String ?? "",
                                             username: item["username"] as? String ?? "", hasTOTP: item["totp"] as? Bool ?? false,
                                             reprompt: item["reprompt"] as? Bool ?? false)
                let uris = (item["uris"] as? [[String: Any]] ?? []).compactMap { u in
                    (u["uri"] as? String).map { LoginIndex.URI($0, rule: (u["match"] as? Int).flatMap(LoginIndex.Rule.init)) }
                }
                return (login, uris)
            }, equivalentDomains: domains)
        }.value
    }

    func credentials(_ id: String) async throws -> Credentials {
        guard let sdk else { throw Failure(message: "Bitwarden is locked") }
        let out = try await sdk.call("login", ["id": id])
        return Credentials(username: out["username"] as? String ?? "", password: out["password"] as? String ?? "",
                           totp: (out["totp"] as? [String: Any])?["code"] as? String)
    }

    /// Master password re-prompt.
    func verify(_ password: String) async throws -> Bool {
        guard let sdk else { throw Failure(message: "Bitwarden is locked") }
        return try await sdk.call("verify", ["password": password])["ok"] as? Bool ?? false
    }

    /// The user key, for "remember unlock".
    func userKey() async throws -> String {
        guard let sdk, let key = try await sdk.call("userKey")["key"] as? String else { throw Failure(message: "Bitwarden is locked") }
        return key
    }

    // MARK: Sync

    /// Checks the account's revision date (at most every five minutes unless forced) and syncs
    /// when it moved. Offline is fine: the cache stays. Rejected credentials log the account out.
    func refresh(force: Bool = false) {
        guard let account, checking == nil, force || lastCheck.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        let id = UUID()
        checking = id
        lastCheck = Date()
        let generation = generation, epoch = accountEpoch
        Task { @MainActor in
            defer { if checking == id { checking = nil } }
            do {
                let server = try Server(account.server)
                let token = try await accessToken(for: account, epoch: epoch)
                let (_, revisionData) = try await HTTP.send(server.api.appending(path: "accounts/revision-date"), bearer: token, device: device)
                let revision = Double(String(decoding: revisionData, as: UTF8.self))
                if !force, revision != nil, revision == self.account?.revision { return }
                let data = try await sync(server: server, token: token, device: device)
                guard epoch == accountEpoch else { return }
                self.account?.revision = revision
                try save(sync: data)
                guard generation == self.generation, let sdk else { return }
                let loaded = try await sdk.call("load", data: data)
                let index = try await Self.index(sdk, domains: loaded["domains"] as? [[String]] ?? [])
                guard generation == self.generation else { return }
                self.index = index
                onChange?()
            } catch is SignedOut {
                guard epoch == accountEpoch else { return }
                try? logOut(expired: true)
                onChange?()
            } catch {}
        }
    }

    private func sync(server: Server, token: String, device: String) async throws -> Data {
        let (status, data) = try await HTTP.send(server.api.appending(path: "sync").appending(queryItems: [.init(name: "excludeDomains", value: "false")]),
                                                 bearer: token, device: device)
        guard status == 200 else { throw Failure(message: status == 0 ? "Can't reach the Bitwarden server" : "Bitwarden sync failed (\(status))") }
        return data
    }

    /// nil = none stored. A keychain that can't be read, or an unreadable item, throws rather
    /// than looking signed out.
    private func loadSecrets() throws -> Secrets? {
        guard let data = try Keychain.read(keychainAccount) else { return nil }
        do { return try JSONDecoder().decode(Secrets.self, from: data) } catch {
            throw Failure(message: "The stored Bitwarden credentials are unreadable; log out and back in")
        }
    }

    private func store(_ secrets: Secrets?) throws {
        if let secrets { try Keychain.write(try JSONEncoder().encode(secrets), keychainAccount) }
        else { try Keychain.delete(keychainAccount) }
    }

    private func save(sync: Data?) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let account { try JSONEncoder().encode(account).write(to: accountFile, options: .atomic) }
        if let sync { try sync.write(to: cacheFile, options: .atomic) }
    }

    /// A live access token: the cached one, else a refresh-token grant (or the API key again).
    /// Nothing is stored if the account changed meanwhile.
    private func accessToken(for account: Account, epoch: UInt64) async throws -> String {
        if let access, access.expires > Date().addingTimeInterval(60) { return access.token }
        guard var secrets = try loadSecrets() else { throw SignedOut() }
        let server = try Server(account.server)
        var form = ["client_id": "web"]
        if let id = secrets.clientId, let secret = secrets.clientSecret {
            form = Identity.deviceForm(device).merging(["grant_type": "client_credentials", "scope": "api", "client_id": id, "client_secret": secret]) { $1 }
        } else if let refresh = secrets.refresh {
            form["grant_type"] = "refresh_token"
            form["refresh_token"] = refresh
        } else { throw SignedOut() }
        let result = try await Identity.token(server, form: form, device: device)
        guard epoch == accountEpoch else { throw CancellationError() }
        switch result {
        case .ok(let body):
            if let refresh = body["refresh_token"] as? String, refresh != secrets.refresh {
                secrets.refresh = refresh
                try store(secrets)
            }
            return adopt(body)
        case .rejected: throw SignedOut()
        default: throw Failure(message: "Bitwarden token refresh failed")
        }
    }

    @discardableResult
    private func adopt(_ body: [String: Any]) -> String {
        let token = body["access_token"] as? String ?? ""
        access = (token, Date().addingTimeInterval(body["expires_in"] as? Double ?? 3600))
        return token
    }

    // MARK: Log in

    /// One login in progress: a fresh SDK session holding the master key derived for the
    /// password grant, so the first unlock skips a second KDF run.
    final class Attempt {
        let serverSetting: String
        let server: Server
        let email: String
        let device: String
        let kdf: KDF
        let sdk: BitwardenSDK
        let form: [String: String]
        let hash: String?
        /// `Bitwarden.epoch` when the login began; a lock, login or logout since cancels it.
        let epoch: UInt64
        var providers: [Int] = []
        var emailHint: String?
        var ssoToken: String?

        init(serverSetting: String, server: Server, email: String, device: String, kdf: KDF, sdk: BitwardenSDK,
             form: [String: String], hash: String?, epoch: UInt64) {
            self.serverSetting = serverSetting; self.server = server; self.email = email; self.device = device
            self.kdf = kdf; self.sdk = sdk; self.form = form; self.hash = hash; self.epoch = epoch
        }
    }

    enum Step { case done, twoFactor(Attempt), newDevice(Attempt) }

    /// Whom a remembered-device token belongs to.
    private static func identity(_ server: Server, _ email: String) -> String {
        server.identity.absoluteString + " " + email.lowercased()
    }

    func logIn(server serverSetting: String, email rawEmail: String, password: String, epoch: UInt64) async throws -> Step {
        let server = try Server(serverSetting)
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pre = try await Identity.prelogin(server, email: email, device: device)
        let sdk = BitwardenSDK()
        let hash = try await sdk.call("authHash", ["salt": pre.salt, "password": password, "kdf": pre.kdf.json])["hash"] as? String ?? ""
        let form = Identity.deviceForm(device).merging([
            "grant_type": "password", "scope": "api offline_access", "client_id": "web", "username": email, "password": hash,
        ]) { $1 }
        let attempt = Attempt(serverSetting: serverSetting, server: server, email: email, device: device, kdf: pre.kdf, sdk: sdk,
                              form: form, hash: hash, epoch: epoch)
        let saved = try? loadSecrets()
        let remembered = saved?.twoFactorFor == Self.identity(server, email) ? saved?.twoFactor : nil
        let extra = remembered.map { ["twoFactorToken": $0, "twoFactorProvider": "5"] } ?? [:]
        return try await submit(attempt, extra: extra)
    }

    /// The API key path (Bitwarden web vault › Settings › Security › Keys): no two-step prompt,
    /// so it also covers accounts whose two-step methods angl can't show (Duo, security keys).
    func logIn(server serverSetting: String, clientId: String, clientSecret: String, password: String, epoch: UInt64) async throws {
        let server = try Server(serverSetting)
        let form = Identity.deviceForm(device).merging([
            "grant_type": "client_credentials", "scope": "api", "client_id": clientId.trimmingCharacters(in: .whitespaces),
            "client_secret": clientSecret.trimmingCharacters(in: .whitespaces),
        ]) { $1 }
        guard case .ok(let body) = try await Identity.token(server, form: form, device: device) else {
            throw Failure(message: "Bitwarden rejected the API key")
        }
        let kdf = Identity.kdf(body) ?? KDF(type: 0, iterations: 600_000)
        let secrets = Secrets(clientId: form["client_id"], clientSecret: form["client_secret"])
        try await finish(Attempt(serverSetting: serverSetting, server: server, email: "", device: device, kdf: kdf, sdk: BitwardenSDK(),
                                 form: form, hash: nil, epoch: epoch), body: body, secrets: secrets, unlock: ["password": password])
    }

    /// Re-submits the password grant with a two-step code or a new-device code.
    func `continue`(_ attempt: Attempt, provider: Int? = nil, code: String, remember: Bool = false) async throws -> Step {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "")
        let extra = provider.map { ["twoFactorToken": code, "twoFactorProvider": String($0), "twoFactorRemember": remember ? "1" : "0"] }
            ?? ["newDeviceOtp": code]
        return try await submit(attempt, extra: extra)
    }

    /// Asks the server to email a two-step code.
    func sendEmailCode(_ attempt: Attempt) async throws {
        var body: [String: Any] = ["email": attempt.email, "deviceIdentifier": attempt.device]
        if let hash = attempt.hash { body["masterPasswordHash"] = hash }
        if let sso = attempt.ssoToken { body["ssoEmail2FaSessionToken"] = sso }
        let (status, _) = try await HTTP.send(attempt.server.api.appending(path: "two-factor/send-email-login"), json: body, device: attempt.device)
        guard (200..<300).contains(status) else { throw Failure(message: "Bitwarden couldn't send the email (\(status))") }
    }

    private func submit(_ attempt: Attempt, extra: [String: String]) async throws -> Step {
        guard attempt.epoch == generation else { throw CancellationError() }
        switch try await Identity.token(attempt.server, form: attempt.form.merging(extra) { $1 }, device: attempt.device) {
        case .ok(let body):
            try await finish(attempt, body: body, secrets: Secrets(refresh: body["refresh_token"] as? String), unlock: ["pending": true])
            return .done
        case .twoFactor(let providers, let hint, let sso):
            if extra["twoFactorProvider"] == "5", var secrets = try? loadSecrets(), secrets.twoFactorFor == Self.identity(attempt.server, attempt.email) {
                // A stale remembered-device token: forget it and ask for a code.
                secrets.twoFactor = nil
                secrets.twoFactorFor = nil
                try? store(secrets)
            }
            attempt.providers = providers; attempt.emailHint = hint; attempt.ssoToken = sso
            return .twoFactor(attempt)
        case .newDevice:
            return .newDevice(attempt)
        case .rejected(let message), .failed(let message):
            throw Failure(message: message)
        }
    }

    /// Syncs and unlocks in the attempt's own SDK session, then commits — unless a lock, login or
    /// logout happened since the attempt began.
    private func finish(_ attempt: Attempt, body: [String: Any], secrets: Secrets, unlock: [String: Any]) async throws {
        guard attempt.epoch == generation else { throw CancellationError() }
        let token = body["access_token"] as? String ?? ""
        var account = Account(server: attempt.serverSetting, email: attempt.email, kdf: Identity.kdf(body) ?? attempt.kdf)
        let data = try await sync(server: attempt.server, token: token, device: attempt.device)
        let loaded = try await attempt.sdk.call("load", data: data)
        if let email = loaded["email"] as? String, !email.isEmpty { account.email = email }
        try await attempt.sdk.call("unlock", unlock.merging(["kdf": account.kdf.json]) { a, _ in a })
        let index = try await Self.index(attempt.sdk, domains: loaded["domains"] as? [[String]] ?? [])
        guard attempt.epoch == generation else { throw CancellationError() }
        var secrets = secrets
        let identity = Self.identity(attempt.server, account.email)
        if let token = Identity.field(body, "TwoFactorToken") as? String {
            secrets.twoFactor = token; secrets.twoFactorFor = identity
        } else if let saved = try? loadSecrets(), saved.twoFactorFor == identity {
            secrets.twoFactor = saved.twoFactor; secrets.twoFactorFor = identity
        }
        try store(secrets)
        lock()
        accountEpoch &+= 1
        checking = nil
        adopt(body)
        self.account = account
        try save(sync: data)
        sdk = attempt.sdk
        self.index = index
        lastCheck = Date()
    }
}

// MARK: - Servers and identity

extension Bitwarden {
    struct Server {
        let identity: URL
        let api: URL

        init(_ setting: String) throws {
            let s = setting.trimmingCharacters(in: .whitespacesAndNewlines)
            switch s.lowercased() {
            case "", "bitwarden.com", "vault.bitwarden.com":
                identity = URL(string: "https://identity.bitwarden.com")!; api = URL(string: "https://api.bitwarden.com")!
            case "bitwarden.eu", "vault.bitwarden.eu":
                identity = URL(string: "https://identity.bitwarden.eu")!; api = URL(string: "https://api.bitwarden.eu")!
            default:
                guard var c = URLComponents(string: s.contains("://") ? s : "https://" + s), let host = c.host, !host.isEmpty,
                      c.scheme == "https" || (c.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
                    throw Failure(message: "Use an https:// server address")
                }
                c.path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
                c.query = nil; c.fragment = nil
                guard let base = c.url else { throw Failure(message: "Invalid server address") }
                identity = base.appending(path: "identity"); api = base.appending(path: "api")
            }
        }
    }

    enum Identity {
        enum Token { case ok([String: Any]), twoFactor([Int], String?, String?), newDevice, rejected(String), failed(String) }

        static func deviceForm(_ device: String) -> [String: String] {
            ["deviceType": String(HTTP.deviceType), "deviceIdentifier": device, "deviceName": "angl"]
        }

        static func prelogin(_ server: Server, email: String, device: String) async throws -> (kdf: KDF, salt: String) {
            var (status, data) = try await HTTP.send(server.identity.appending(path: "accounts/prelogin/password"), json: ["email": email], device: device)
            if status == 404 || status == 405 {
                (status, data) = try await HTTP.send(server.identity.appending(path: "accounts/prelogin"), json: ["email": email], device: device)
            }
            guard status == 200, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let kdf = kdf(body) else {
                throw Failure(message: status == 0 ? "Can't reach the Bitwarden server" : "Bitwarden prelogin failed (\(status))")
            }
            return (kdf, (field(body, "salt") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? email)
        }

        /// KDF parameters from a prelogin or token response: nested `kdfSettings` (current
        /// servers) before the legacy flat fields.
        static func kdf(_ body: [String: Any]) -> KDF? {
            if let s = field(body, "kdfSettings") as? [String: Any], let type = field(s, "kdfType") as? Int,
               let iterations = field(s, "iterations") as? Int {
                return KDF(type: type, iterations: iterations, memory: field(s, "memory") as? Int, parallelism: field(s, "parallelism") as? Int)
            }
            guard let type = field(body, "kdf") as? Int, let iterations = field(body, "kdfIterations") as? Int else { return nil }
            return KDF(type: type, iterations: iterations, memory: field(body, "kdfMemory") as? Int, parallelism: field(body, "kdfParallelism") as? Int)
        }

        static func token(_ server: Server, form: [String: String], device: String) async throws -> Token {
            let (status, data) = try await HTTP.send(server.identity.appending(path: "connect/token"), form: form, device: device)
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if status == 200, body["access_token"] is String { return .ok(body) }
            if let providers = field(body, "TwoFactorProviders2") as? [String: Any] {
                let email = (providers["1"] as? [String: Any]).flatMap { field($0, "Email") as? String }
                return .twoFactor(providers.keys.compactMap(Int.init).sorted(), email, field(body, "SsoEmail2faSessionToken") as? String)
            }
            let message = (field(body, "ErrorModel") as? [String: Any]).flatMap { field($0, "Message") as? String }
                ?? (field(body, "error_description") as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (status == 0 ? "Can't reach the Bitwarden server" : "Bitwarden login failed (\(status))")
            if message.lowercased().contains("new device verification required") { return .newDevice }
            // Rejected = the identity server refused these credentials: OAuth's invalid_grant /
            // invalid_client, or (Vaultwarden) a 400 carrying its error model. Anything else —
            // proxies, outages, odd 400s — is a plain failure that keeps the session.
            let error = field(body, "error") as? String
            if error == "invalid_grant" || error == "invalid_client" || (status == 400 && field(body, "ErrorModel") is [String: Any]) {
                return .rejected(message)
            }
            return .failed(message)
        }

        /// Bitwarden mixes PascalCase and camelCase between servers and versions.
        static func field(_ body: [String: Any], _ key: String) -> Any? {
            if let v = body[key], !(v is NSNull) { return v }
            let lower = key.lowercased()
            return body.first { $0.key.lowercased() == lower && !($0.value is NSNull) }?.value
        }
    }

    enum HTTP {
        /// DeviceType.SDK: angl talks to Bitwarden through the Bitwarden SDK.
        static let deviceType = 21
        private static let session: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.httpCookieStorage = nil
            c.urlCache = nil
            c.timeoutIntervalForRequest = 30
            return URLSession(configuration: c)
        }()

        /// (status, body); status 0 = unreachable.
        static func send(_ url: URL, form: [String: String]? = nil, json: [String: Any]? = nil, bearer: String? = nil,
                         device: String) async throws -> (Int, Data) {
            var r = URLRequest(url: url)
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            r.setValue(String(deviceType), forHTTPHeaderField: "Device-Type")
            r.setValue(device, forHTTPHeaderField: "Device-Identifier")
            r.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            if let bearer { r.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
            if let form {
                r.httpMethod = "POST"
                r.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
                r.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                    .joined(separator: "&").utf8)
            } else if let json {
                r.httpMethod = "POST"
                r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONSerialization.data(withJSONObject: json)
            }
            do {
                let (data, response) = try await session.data(for: r)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return (0, Data())
            }
        }
    }
}

// MARK: - SDK session

/// One official-SDK session (bitwarden/src/lib.rs). Calls run in order on a private queue, off
/// the main thread. Freeing the session drops and zeroes every key it holds.
final class BitwardenSDK: @unchecked Sendable {
    private let session: OpaquePointer
    private let queue = DispatchQueue(label: "dev.btuckerc.angl.bitwarden", qos: .userInitiated)

    init() { session = angl_bw_new() }
    deinit { angl_bw_free(session) }

    @discardableResult
    @MainActor
    func call(_ method: String, _ input: [String: Any] = [:]) async throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: input)
        defer { data.resetBytes(in: 0..<data.count) }
        return try await call(method, data: data)
    }

    @discardableResult
    func call(_ method: String, data: Data) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            queue.async {
                let buf = data.withUnsafeBytes { angl_bw_call(self.session, method, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
                var out = buf.ptr.map { Data(bytes: $0, count: buf.len) } ?? Data()
                angl_bw_buf_free(buf)
                defer { out.resetBytes(in: 0..<out.count) }
                guard let reply = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] else {
                    return continuation.resume(throwing: Bitwarden.Failure(message: "Bitwarden SDK returned nothing"))
                }
                if let error = reply["error"] as? [String: Any] {
                    let kind = error["kind"] as? String ?? ""
                    let failure = kind == "wrongPassword" ? Bitwarden.Failure(message: "Wrong master password", wrongPassword: true)
                        : Bitwarden.Failure(message: "Bitwarden: \(error["message"] as? String ?? kind)")
                    return continuation.resume(throwing: failure)
                }
                continuation.resume(returning: reply["ok"] as? [String: Any] ?? [:])
            }
        }
    }
}

// MARK: - Keychain

/// Generic passwords in the login keychain under one service.
enum Keychain {
    static let service = "dev.btuckerc.angl.bitwarden"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// nil = no such item.
    static func read(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Bitwarden.Failure(message: "Keychain read failed (\(status))") }
        return out as? Data
    }

    static func exists(_ account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Replaces in place, so a failed write never loses the previous value.
    static func write(_ data: Data, _ account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query(account).merging(attributes) { $1 } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw Bitwarden.Failure(message: "Keychain write failed (\(status))") }
    }

    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Bitwarden.Failure(message: "Keychain delete failed (\(status))") }
    }
}

// MARK: - Remembered unlock

/// "Remember unlock": the user key sealed (ECIES: P-256 + HKDF-SHA256 + AES-GCM) to a Secure
/// Enclave key whose use needs Touch ID or the login password. The keychain item holds only the
/// sealed box and the enclave key's device-bound blob, so reading it releases nothing.
@MainActor
enum SealedKey {
    private struct Box: Codable { var key: Data; var ephemeral: Data; var sealed: Data }

    static var available: Bool { SecureEnclave.isAvailable }

    private static func access() throws -> SecAccessControl {
        guard let a = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], nil) else {
            throw Bitwarden.Failure(message: "Secure Enclave access control unavailable")
        }
        return a
    }

    /// No prompt: sealing uses only the enclave key's public half.
    static func seal(_ secret: Data) throws -> Data {
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access())
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let symmetric = derive(try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey), ephemeral.publicKey, key.publicKey)
        guard let sealed = try AES.GCM.seal(secret, using: symmetric).combined else { throw Bitwarden.Failure(message: "Sealing failed") }
        return try JSONEncoder().encode(Box(key: key.dataRepresentation, ephemeral: ephemeral.publicKey.rawRepresentation, sealed: sealed))
    }

    /// Asks for Touch ID or the login password, then opens the box.
    static func open(_ data: Data, reason: String) async throws -> Data {
        let box = try JSONDecoder().decode(Box.self, from: data)
        let context = LAContext()
        try await context.evaluateAccessControl(access(), operation: .useKeyKeyExchange, localizedReason: reason)
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: box.key, authenticationContext: context)
        let ephemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: box.ephemeral)
        let symmetric = derive(try key.sharedSecretFromKeyAgreement(with: ephemeral), ephemeral, key.publicKey)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: box.sealed), using: symmetric)
    }

    private static func derive(_ secret: SharedSecret, _ ephemeral: P256.KeyAgreement.PublicKey,
                               _ recipient: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("angl.bitwarden.remember".utf8),
                                       sharedInfo: ephemeral.rawRepresentation + recipient.rawRepresentation, outputByteCount: 32)
    }
}
