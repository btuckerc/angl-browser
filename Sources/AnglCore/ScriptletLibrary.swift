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
        // Byte-wise: splitting 600 KB by Character costs ~8 ms of launch; by UTF-8 byte, ~2. Every
        // anchor below is ASCII, so its UTF-8 offsets are also character offsets.
        for bytes in source.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let line = Substring(bytes)
            if bytes.starts(with: "function ".utf8), let paren = bytes.firstIndex(of: UInt8(ascii: "(")) {
                seenFunction = true
                definitions[line[line.utf8.index(line.startIndex, offsetBy: 9)..<paren]] = line
            } else if bytes.starts(with: "functions[\"".utf8), bytes.last == UInt8(ascii: ";"), let close = line.range(of: "\"]=") {
                let name = line[line.utf8.index(line.startIndex, offsetBy: 11)..<close.lowerBound]
                registrations[name] = (line[close.upperBound..<line.utf8.index(before: line.endIndex)], line)
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
