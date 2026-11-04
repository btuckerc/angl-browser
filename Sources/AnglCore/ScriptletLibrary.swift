import Foundation

/// The vendored AdGuard scriptlets bundle (Resources/web/inject/adguard-scriptlets.js) cut down to
/// what one page uses. The bundle is ~600 KB: a prologue, one self-contained
/// `function name(source,args){…}` per line, `functions["scriptlet-name"]=name;` registrations,
/// then the `__anglAdGuardScriptlets` epilogue. Injecting all of it into every frame of every
/// page costs a parse per frame; a page's rules usually call a handful of scriptlets.
public struct ScriptletLibrary: Sendable {
    private let whole: String
    private var prologue: [Substring] = []
    private var epilogue: [Substring] = []
    private var definitions: [Substring: Substring] = [:]  // function name → its definition line
    private var registrations: [Substring: (function: Substring, line: Substring)] = [:]  // scriptlet name → registration

    public init(_ source: String) {
        whole = source
        var seenFunction = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("function "), let paren = line.firstIndex(of: "(") {
                seenFunction = true
                definitions[line[line.index(line.startIndex, offsetBy: 9)..<paren]] = line
            } else if line.hasPrefix("functions[\""), let close = line.range(of: "\"]="), line.hasSuffix(";") {
                let name = line[line.index(line.startIndex, offsetBy: 11)..<close.lowerBound]
                registrations[name] = (line[close.upperBound..<line.index(before: line.endIndex)], line)
            } else if seenFunction {
                epilogue.append(line)
            } else {
                prologue.append(line)
            }
        }
    }

    /// The bundle with only the functions behind `names` registered. A bundle not in the expected
    /// shape comes back whole, so a re-vendored build can't silently drop scriptlets.
    public func source(for names: [String]) -> String {
        guard !definitions.isEmpty, !registrations.isEmpty else { return whole }
        var lines = prologue
        var defined = Set<Substring>()
        for name in Set(names).sorted() {
            guard let r = registrations[Substring(name)], let definition = definitions[r.function] else { continue }
            if defined.insert(r.function).inserted { lines.append(definition) }
            lines.append(r.line)
        }
        return (lines + epilogue).joined(separator: "\n")
    }
}
