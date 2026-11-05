import AnglCore
import AppKit
import WebKit

/// What angl changed to show a page in instant full screen, to put back when it ends.
struct PageFullscreenState {
    weak var tab: Tab?
    /// Set when angl took the whole screen rather than only hiding its chrome in the window.
    var screen: (frame: NSRect, styleMask: NSWindow.StyleMask, presentation: NSApplication.PresentationOptions, background: NSColor?)?
    /// The notch: the page sits below the screen's safe area, as in macOS full screen.
    var topInset: CGFloat = 0
    /// Esc, taken before the page (or a frame in it) can swallow it, as WebKit's full screen does.
    var escape: Any?
}

/// fullscreen-gate.js → app, main frame only: `{on}`. Replies whether the page may enter (it had a
/// user gesture by then) or has left.
@MainActor
final class FullscreenBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "anglFullscreen"
    private weak var tab: Tab?

    init(_ tab: Tab) { self.tab = tab }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let tab, message.frameInfo.isMainFrame, message.webView === tab.webView,
              let on = (message.body as? [String: Any])?["on"] as? Bool else { replyHandler(false, nil); return }
        if on {
            replyHandler(tab.owner.beginPageFullscreen(for: tab), nil)
        } else {
            tab.owner.endPageFullscreen(of: tab, tellPage: false)
            replyHandler(true, nil)
        }
    }
}

extension BrowserWindowController {
    /// The page asked for full screen: its tab fills the screen (or the window) at once, in the
    /// current Space, with no system animation. Only the active tab, one window at a time
    /// (presentation options are the app's, so only one window may own them).
    func beginPageFullscreen(for tab: Tab) -> Bool {
        let mode = browser.settings.content.fullscreen
        guard let window, tab === active, mode != .native else { return false }
        if pageFullscreen?.tab === tab { return true }
        endPageFullscreen(of: nil, tellPage: true)
        for other in browser.windows where other !== self { other.endPageFullscreen(of: nil, tellPage: true) }
        var state = PageFullscreenState(tab: tab)
        // Already in macOS full screen, the window is the screen: hiding the chrome is enough.
        if mode == .screen, !window.styleMask.contains(.fullScreen), let screen = window.screen {
            state.screen = (window.frame, window.styleMask, NSApp.presentationOptions, window.backgroundColor)
            state.topInset = screen.safeAreaInsets.top
            let responder = window.firstResponder
            // Borderless: square corners and no title bar; the menu bar and Dock slide in on demand.
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            window.styleMask = [.borderless]
            window.backgroundColor = .black
            window.setFrame(screen.frame, display: false)
            window.makeFirstResponder(responder)
        }
        state.escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]) else { return event }
            let number = event.windowNumber
            let taken = MainActor.assumeIsolated {
                guard let self, number == self.window?.windowNumber else { return false }
                self.endPageFullscreen(of: nil, tellPage: true)
                return true
            }
            return taken ? nil : event
        }
        pageFullscreen = state
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        toast("\(tab.url?.host() ?? "page") is full screen · Esc exits", color: style.secondary)
        return true
    }

    /// Ends instant full screen for `tab` (nil: whichever page has it). `tellPage` when the page
    /// still shows its element full screen (Esc in angl, a tab switch, ⌃⌘F); not when its
    /// document is gone or it asked to leave.
    func endPageFullscreen(of tab: Tab?, tellPage: Bool) {
        guard let state = pageFullscreen, tab == nil || state.tab === tab else { return }
        pageFullscreen = nil
        if let escape = state.escape { NSEvent.removeMonitor(escape) }
        if tellPage {
            state.tab?.webView?.evaluateJavaScript("window.__anglFullscreenGate?.end()", in: nil, in: InjectedScripts.world) { _ in }
        }
        if let saved = state.screen, let window {
            let responder = window.firstResponder
            window.styleMask = saved.styleMask
            window.backgroundColor = saved.background
            window.setFrame(saved.frame, display: false)
            NSApp.presentationOptions = saved.presentation
            window.makeFirstResponder(responder)
        }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }

    /// content.autoPictureInPicture: the tab switched away from takes its playing video to Picture
    /// in Picture; the tab switched to gets back the video it sent there.
    func switchPictureInPicture(from previous: Tab?, to next: Tab) {
        if next.autoPictureInPicture {
            next.autoPictureInPicture = false
            Task { await next.pictureInPicture(.exit) }
        }
        guard browser.settings.content.autoPictureInPicture, let previous, previous.isPlaying,
              previous.webView?.superview == nil else { return }
        previous.autoPictureInPicture = true
        Task { [weak self] in
            guard await previous.pictureInPicture(.enter) == .on else { previous.autoPictureInPicture = false; return }
            // Came back while it was entering: the exit above found nothing to end.
            if self?.active === previous || previous.webView?.superview != nil {
                previous.autoPictureInPicture = false
                await previous.pictureInPicture(.exit)
            }
        }
    }
}
