import AnglCore
import Foundation
import WebKit

struct Emote: Sendable {
    let url1x: String
    let url2x: String
    let static1x: String?
    let static2x: String?
    let animated: Bool
    let zeroWidth: Bool
    let provider: String
}

/// Name collisions resolve channel 7TV > BTTV > FFZ, then global 7TV > BTTV > FFZ.
/// Public provider metadata only; page input selects a channel, never a URL.
@MainActor
final class EmoteService {
    static let shared = EmoteService()
    private struct Entry { let map: [String: Emote]; let expires: Date }
    private var channels: [String: Entry] = [:]
    private var pending: [String: Task<[String: Emote], Never>] = [:]
    private var globals: [String: [String: Emote]] = [:]
    private let session: URLSession = .shared
    private init() {}

    func emotes(channel: String, twitchID: String?, settings: Settings.Twitch) async -> [String: [String: Any]] {
        let login = channel.lowercased()
        guard !login.isEmpty, login.range(of: #"^[a-z0-9_]{1,25}$"#, options: .regularExpression) != nil else { return [:] }
        let key = login + ":" + (twitchID ?? "") + ":\(settings.bttv):\(settings.ffz):\(settings.seventv)"
        let now = Date()
        var map: [String: Emote]
        if let cached = channels[key], cached.expires > now { map = cached.map }
        else {
            let task = pending[key] ?? Task { await Self.fetchChannel(login: login, id: twitchID, settings: settings, session: session) }
            pending[key] = task
            map = await task.value
            pending[key] = nil
            channels[key] = Entry(map: map, expires: now.addingTimeInterval(600))
            if channels.count > 20, let oldest = channels.min(by: { $0.value.expires < $1.value.expires })?.key { channels.removeValue(forKey: oldest) }
        }
        for provider in ["7tv", "bttv", "ffz"] where (provider == "7tv" ? settings.seventv : provider == "bttv" ? settings.bttv : settings.ffz) {
            if globals[provider] == nil {
                let fetched = await Self.fetchGlobal(provider, session: session)
                if !fetched.isEmpty { globals[provider] = fetched }
            }
            for (code, value) in globals[provider] ?? [:] where map[code] == nil { map[code] = value }
        }
        return map.mapValues { emote in
            let url1x = !settings.animated ? (emote.static1x ?? emote.url1x) : emote.url1x
            let url2x = !settings.animated ? (emote.static2x ?? emote.url2x) : emote.url2x
            return ["url1x": url1x, "url2x": url2x, "animated": emote.animated, "zeroWidth": emote.zeroWidth, "provider": emote.provider]
        }
    }

    private static func json(_ url: String, session: URLSession) async -> Any? {
        guard let url = URL(string: url), let (data, _) = try? await session.data(from: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
    private static func fetchChannel(login: String, id pageID: String?, settings: Settings.Twitch, session: URLSession) async -> [String: Emote] {
        var m: [String: Emote] = [:]
        // FFZ's room record carries the Twitch user ID; the page DOM rarely does.
        let ffzRoom = await json("https://api.frankerfacez.com/v1/room/\(login)", session: session) as? [String: Any]
        let ffzID = (ffzRoom?["room"] as? [String: Any])?["twitch_id"].map { "\($0)" }
        var id = pageID ?? ffzID
        if id == nil, settings.seventv || settings.bttv { id = await twitchID(login: login, session: session) }
        if settings.seventv, let id, let obj = await json("https://7tv.io/v3/users/twitch/\(id)", session: session) as? [String: Any],
           let set = obj["emote_set"] as? [String: Any], let entries = set["emotes"] as? [[String: Any]] {
            for e in entries { if let em = seven(e), let name = e["name"] as? String { m[name] = em } }
        }
        if settings.bttv, let id, let obj = await json("https://api.betterttv.net/3/cached/users/twitch/\(id)", session: session) as? [String: Any] {
            for k in ["channelEmotes", "sharedEmotes"] { for e in obj[k] as? [[String: Any]] ?? [] { if let em = bttv(e), let name = e["code"] as? String, m[name] == nil { m[name] = em } } }
        }
        if settings.ffz, let sets = ffzRoom?["sets"] as? [String: Any] {
            var ffz: [String: Emote] = [:]
            appendFFZ(sets, to: &ffz)
            for (name, em) in ffz where m[name] == nil { m[name] = em }
        }
        return m
    }

    /// Login → Twitch user ID via Twitch's own web GraphQL endpoint (public web client ID).
    private static func twitchID(login: String, session: URLSession) async -> String? {
        guard let url = URL(string: "https://gql.twitch.tv/gql") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("kimne78kx3ncx6brgo4mv6wki5h1ko", forHTTPHeaderField: "Client-Id")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": "query{user(login:\"\(login)\"){id}}"])
        guard let (data, _) = try? await session.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = (obj["data"] as? [String: Any])?["user"] as? [String: Any] else { return nil }
        return user["id"] as? String
    }
    private static func fetchGlobal(_ p: String, session: URLSession) async -> [String: Emote] {
        var m: [String: Emote] = [:]
        switch p {
        case "bttv":
            for e in await json("https://api.betterttv.net/3/cached/emotes/global", session: session) as? [[String: Any]] ?? [] { if let x = bttv(e), let n = e["code"] as? String { m[n] = x } }
        case "ffz":
            if let o = await json("https://api.frankerfacez.com/v1/set/global", session: session) as? [String: Any],
               let defaults = o["default_sets"] as? [NSNumber] {
                let sets = o["sets"] as? [String: Any] ?? [:]
                for id in defaults { let key = id.stringValue; if let s = sets[key] as? [String: Any] { appendFFZ([key: s], to: &m) } }
            }
        default:
            if let o = await json("https://7tv.io/v3/emote-sets/global", session: session) as? [String: Any], let a = o["emotes"] as? [[String: Any]] { for e in a { if let x = seven(e), let n = e["name"] as? String { m[n] = x } } }
        }
        return m
    }
    private static func bttv(_ e: [String: Any]) -> Emote? {
        guard let id = e["id"] as? String else { return nil }
        let animated = e["imageType"] as? String == "gif"
        let ext = animated ? "gif" : (e["imageType"] as? String ?? "png")
        let base = "https://cdn.betterttv.net/emote/\(id)/"
        return Emote(url1x: base + "1x.\(ext)", url2x: base + "2x.\(ext)", static1x: animated ? base + "1x.png" : nil, static2x: animated ? base + "2x.png" : nil, animated: animated, zeroWidth: false, provider: "bttv")
    }
    private static func seven(_ e: [String: Any]) -> Emote? {
        guard let data = e["data"] as? [String: Any], let host = data["host"] as? [String: Any], let url = host["url"] as? String,
              let files = host["files"] as? [[String: Any]], let file2 = files.first(where: { ($0["name"] as? String)?.contains("2x") == true }) ?? files.first,
              let file1 = files.first(where: { ($0["name"] as? String)?.contains("1x") == true }) ?? files.first else { return nil }
        let animated = data["animated"] as? Bool ?? false
        let base = url.hasPrefix("//") ? "https:" + url : "https://" + url
        let path1 = file1["name"] as? String ?? ""
        let path2 = file2["name"] as? String ?? ""
        let static1 = file1["static_name"] as? String
        let static2 = file2["static_name"] as? String
        return Emote(url1x: base + "/" + path1, url2x: base + "/" + path2, static1x: static1.map { base + "/" + $0 }, static2x: static2.map { base + "/" + $0 }, animated: animated, zeroWidth: ((e["flags"] as? Int) ?? 0) & 1 != 0, provider: "7tv")
    }
    private static func appendFFZ(_ sets: [String: Any], to map: inout [String: Emote]) {
        for s in sets.values.compactMap({ $0 as? [String: Any] }) {
            for e in s["emoticons"] as? [[String: Any]] ?? [] {
                guard let name = e["name"] as? String else { continue }
                let urls = e["urls"] as? [String: String] ?? [:]
                guard let url = urls["1"] ?? urls["2"] else { continue }
                let full = url.hasPrefix("//") ? "https:" + url : url
                map[name] = Emote(url1x: full, url2x: urls["2"].map { $0.hasPrefix("//") ? "https:" + $0 : $0 } ?? full, static1x: nil, static2x: nil, animated: false, zeroWidth: false, provider: "ffz")
            }
        }
    }
}

@MainActor
final class TwitchEmoteBridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.frameInfo.securityOrigin.protocol == "https", ["twitch.tv", "www.twitch.tv", "m.twitch.tv"].contains(message.frameInfo.securityOrigin.host),
              let body = message.body as? [String: Any], let channel = body["channel"] as? String else { replyHandler([:], nil); return }
        let id = body["id"] as? String
        let settings = Browser.shared.settings.twitch
        Task { @MainActor in replyHandler(await EmoteService.shared.emotes(channel: channel, twitchID: id, settings: settings), nil) }
    }
}
