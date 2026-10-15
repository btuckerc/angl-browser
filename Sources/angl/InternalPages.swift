import AnglCore
import AppKit
import UniformTypeIdentifiers
import WebKit

/// Serves angl:// pages from Resources/web and generates angl://theme.css from the theme tokens.
@MainActor
final class InternalPages: NSObject, WKURLSchemeHandler {
    static let scheme = "angl"
    static let pages: Set<String> = ["settings", "spaces", "sites", "history", "downloads", "snapshots", "about"]

    static func url(_ page: String, fragment: String? = nil) -> URL {
        URL(string: "angl://\(page)" + (fragment.map { "#\($0)" } ?? ""))!
    }

    static func title(for url: URL) -> String {
        "angl " + (url.host() ?? "")
    }

    private var webRoot: URL {
        Bundle.main.resourceURL?.appendingPathComponent("web")
            ?? URL(fileURLWithPath: "Resources/web", isDirectory: true)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task) }
        let host = url.host() ?? ""
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let data: Data?
        let mime: String
        if host == "theme.css" {
            let b = Browser.shared!
            var css = b.theme.cssVariables
            css += (try? String(contentsOf: b.paths.cssDir.appendingPathComponent("_angl.css"), encoding: .utf8)) ?? ""
            data = Data(css.utf8)
            mime = "text/css"
        } else if InternalPages.pages.contains(host) {
            let file = path.isEmpty ? "\(host).html" : path
            // No path traversal: only plain file names inside Resources/web.
            guard !file.contains(".."), !file.hasPrefix("/") else { return fail(task) }
            let u = webRoot.appendingPathComponent(file)
            data = try? Data(contentsOf: u)
            mime = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        } else {
            data = nil
            mime = "text/plain"
        }
        guard let data else { return fail(task) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime + (mime.hasPrefix("text/") || mime.hasSuffix("javascript") ? "; charset=utf-8" : ""),
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src angl:; img-src angl: data: https: http:; style-src angl: 'unsafe-inline'; script-src angl:",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func fail(_ task: any WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }
}

/// The `angl` message handler internal pages call through common.js. Only angl:// main frames
/// may use it; web pages can't reach it.
@MainActor
final class PageBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = PageBridge()
    static let name = "angl"

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == InternalPages.scheme,
              let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "not allowed")
            return
        }
        let args = body["args"] as? [String: Any] ?? [:]
        let window = (message.webView?.window?.windowController as? BrowserWindowController)
        Task { @MainActor in
            do {
                let reply = try await PageCommands.run(cmd, args: args, window: window)
                replyHandler(reply, nil)
            } catch {
                replyHandler(nil, (error as? PageCommands.Failure)?.message ?? error.localizedDescription)
            }
        }
    }
}
