import AppKit

// Block-list worker child (ListWorker); never returns.
if CommandLine.arguments.dropFirst().first == "--lists" { ListWorker.main() }

MainActor.assumeIsolated {
    // No AutoFill guessing in native fields: focusing any text field would otherwise start the
    // "AutoFill (angl)" helper process for the app's lifetime. Read when NSApplication is created,
    // so it must be registered first. The explicit Apple Passwords command still opens its panel.
    UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
