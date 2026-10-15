import Foundation

/// "Engines": angl renders with WebKit; other installed browsers are engines a tab or a site
/// can be handed to (Chromium for a site that only works there, Safari for passkeys).
public struct Engine: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bundleID: String
    public var family: String

    public static let known: [Engine] = [
        Engine(id: "safari", name: "Safari", bundleID: "com.apple.Safari", family: "WebKit"),
        Engine(id: "orion", name: "Orion", bundleID: "com.kagi.kagimacOS", family: "WebKit"),
        Engine(id: "chrome", name: "Chrome", bundleID: "com.google.Chrome", family: "Chromium"),
        Engine(id: "helium", name: "Helium", bundleID: "net.imput.helium", family: "Chromium"),
        Engine(id: "brave", name: "Brave", bundleID: "com.brave.Browser", family: "Chromium"),
        Engine(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", family: "Gecko"),
        Engine(id: "librewolf", name: "LibreWolf", bundleID: "org.mozilla.librewolf", family: "Gecko"),
        Engine(id: "zen", name: "Zen", bundleID: "app.zen-browser.zen", family: "Gecko"),
    ]

    public static func engine(id: String) -> Engine? { known.first { $0.id == id } }

    /// The engine rule claiming `url`, if any.
    public static func rule(for url: URL, in rules: [EngineRule]) -> EngineRule? {
        rules.first { $0.match.matches(url) }
    }
}
