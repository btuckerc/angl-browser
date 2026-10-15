import ContentBlockerConverter
import CryptoKit
import FilterEngine
import Foundation

/// Converts filter subscriptions using AdGuard's Safari converter.
public enum FilterListConverter {
    public static let maxRulesPerList = 150_000

    public struct Output: Sendable {
        public var chunks: [String]
        public var ruleCount: Int
        public var skipped: Int
        public var advancedRulesText: String
        public var advancedRuleCount: Int
    }

    public static func convert(_ texts: [String]) -> Output {
        convert(texts, maxRulesPerList: maxRulesPerList)
    }

    static func convert(_ texts: [String], maxRulesPerList cap: Int) -> Output {
        let cap = max(1, cap)
        let ruleLists = texts.map { $0.split(whereSeparator: \.isNewline).map(String.init) }
        let lines = ruleLists.flatMap { $0 }
        let converter = ContentBlockerConverter()
        let advanced = converter.convertArray(
            rules: lines, safariVersion: .safari26, advancedBlocking: true,
            maxJsonSizeBytes: nil, progress: nil
        )
        let exceptions = lines.filter(isException)
        var convertedRules: [[String: Any]] = []
        var exceptionRules: [String: [String: Any]] = [:]
        var undistributed = 0

        func append(_ batch: [String]) {
            let result = converter.convertArray(
                rules: batch + exceptions, safariVersion: .safari26,
                advancedBlocking: false, maxJsonSizeBytes: nil, progress: nil
            )
            if result.discardedSafariRules > 0, batch.count > 1 {
                let midpoint = batch.count / 2
                append(Array(batch[..<midpoint]))
                append(Array(batch[midpoint...]))
                return
            }
            guard let data = result.safariRulesJSON.data(using: .utf8),
                  let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                undistributed += result.safariRulesCount
                return
            }
            for rule in rules {
                if (rule["action"] as? [String: String])?["type"] == "ignore-previous-rules" {
                    let trigger = rule["trigger"] as? [String: Any]
                    if (trigger?["if-domain"] as? [String]) == ["domain.com"],
                       (trigger?["url-filter"] as? String) == ".*" {
                        continue
                    }
                    guard let encoded = try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys]),
                          let key = String(data: encoded, encoding: .utf8) else { continue }
                    exceptionRules[key] = rule
                } else {
                    convertedRules.append(rule)
                }
            }
            undistributed += result.discardedSafariRules
        }

        for rules in ruleLists {
            let ordinary = rules.filter { !isException($0) }
            for start in stride(from: 0, to: ordinary.count, by: 10_000) {
                append(Array(ordinary[start..<min(start + 10_000, ordinary.count)]))
            }
        }
        if convertedRules.isEmpty && exceptionRules.isEmpty { append([]) }

        let sharedExceptions = exceptionRules.keys.sorted().compactMap { exceptionRules[$0] }
        let ordinaryLimit = cap - sharedExceptions.count
        guard ordinaryLimit > 0 else {
            let emptyResult = #"[{"action":{"type":"ignore-previous-rules"},"trigger":{"if-domain":["domain.com"],"url-filter":".*"}}]"#
            return Output(chunks: [emptyResult], ruleCount: 1, skipped: advanced.errorsCount + undistributed + sharedExceptions.count,
                          advancedRulesText: advanced.advancedRulesText ?? "", advancedRuleCount: advanced.advancedRulesCount)
        }
        var chunks: [String] = []
        let ruleBatches: [ArraySlice<[String: Any]>]
        if convertedRules.isEmpty {
            ruleBatches = []
        } else {
            ruleBatches = stride(from: 0, to: convertedRules.count, by: ordinaryLimit).map { start in
                convertedRules[start..<min(start + ordinaryLimit, convertedRules.count)]
            }
        }
        for batch in ruleBatches {
            guard let data = try? JSONSerialization.data(
                withJSONObject: Array(batch) + sharedExceptions,
                options: [.sortedKeys]
            ), let text = String(data: data, encoding: .utf8) else { continue }
            chunks.append(text)
        }
        if chunks.isEmpty {
            let data = try? JSONSerialization.data(withJSONObject: sharedExceptions, options: [.sortedKeys])
            let exceptionsJSON = data.flatMap { String(data: $0, encoding: .utf8) }
            chunks = [exceptionsJSON.flatMap { $0 == "[]" ? nil : $0 } ?? #"[{"action":{"type":"ignore-previous-rules"},"trigger":{"if-domain":["domain.com"],"url-filter":".*"}}]"#]
        }
        return Output(
            chunks: chunks,
            ruleCount: max(1, convertedRules.count + sharedExceptions.count * chunks.count),
            skipped: advanced.errorsCount + undistributed,
            advancedRulesText: advanced.advancedRulesText ?? "",
            advancedRuleCount: advanced.advancedRulesCount
        )
    }

    private static func isException(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("@@") || line.contains("#@#")
            || line.contains("#@?#") || line.contains("#@%#")
    }

    /// Returns the indexed, URL-specific set of advanced cosmetic/scriptlet rules.
    public static func advancedEntries(for url: URL, storageURL: URL, indexURL: URL) throws -> [AdvancedEntry] {
        try AdvancedRuleLookup(storageURL: storageURL, indexURL: indexURL).entries(for: url)
    }

    public struct AdvancedEntry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case scriptlet, extendedCSS, cssInject }
        public var kind: Kind
        public var content: String
    }

    public struct ScriptletInvocation: Sendable {
        public var name: String
        public var arguments: [String]
    }

    public static func scriptletInvocation(_ content: String) -> ScriptletInvocation? {
        guard content.hasPrefix("//scriptlet("), content.last == ")" else { return nil }
        let body = content.dropFirst("//scriptlet(".count).dropLast()
        var values: [String] = []
        var value = ""
        var quote: Character?
        var escaped = false
        for character in body {
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { value.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "," {
                values.append(value.trimmingCharacters(in: .whitespaces))
                value = ""
            } else if !character.isWhitespace {
                value.append(character)
            }
        }
        if escaped || quote != nil { return nil }
        values.append(value.trimmingCharacters(in: .whitespaces))
        guard let name = values.first, !name.isEmpty else { return nil }
        return ScriptletInvocation(name: name, arguments: Array(values.dropFirst()))
    }

    public static func fontBlockList() -> String {
        "[{\"action\":{\"type\":\"block\"},\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"font\"]}}]"
    }
}

/// Runtime reader for the prebuilt SafariConverterLib advanced-rule index.
public final class AdvancedRuleLookup {
    private let storage: FilterRuleStorage
    private let engine: FilterEngine

    public init(storageURL: URL, indexURL: URL) throws {
        storage = try FilterRuleStorage(fileURL: storageURL)
        engine = try FilterEngine(storage: storage, indexFileURL: indexURL)
    }

    public func entries(for url: URL) -> [FilterListConverter.AdvancedEntry] {
        engine.findAll(for: Request(url: url)).compactMap { rule in
            guard let content = rule.cosmeticContent else { return nil }
            if rule.action.contains(.scriptlet) {
                return FilterListConverter.AdvancedEntry(kind: .scriptlet, content: content)
            }
            if rule.action.contains(.extendedCSS) {
                return FilterListConverter.AdvancedEntry(kind: .extendedCSS, content: content)
            }
            if rule.action.contains(.cssInject) {
                return FilterListConverter.AdvancedEntry(kind: .cssInject, content: content)
            }
            return nil
        }
    }
}

/// Artifacts generated from filter subscriptions.
public struct FilterListManifest: Codable, Sendable {
    public struct Chunk: Codable, Sendable {
        public var id: String
        public var file: String
        public var rules: Int
    }

    public var generated: Date
    public var skipped: Int
    public var chunks: [Chunk]
    public var advancedRules: Int
    public var conversionSeconds: Double
    public var advancedRulesFile: String
    public var advancedStorageFile: String
    public var advancedIndexFile: String
    /// URLs of the enabled lists this was built from, in order (nil: built before this was recorded).
    public var sources: [String]?
    /// Names of enabled lists whose download failed; the build used the rest.
    public var failed: [String]?

    /// What a manifest for these settings must have been built from.
    public static func sources(for lists: [FilterList]) -> [String] { lists.filter(\.enabled).map(\.url) }

    public static func build(lists: [FilterList], into dir: URL) async throws -> FilterListManifest {
        let enabled = lists.filter(\.enabled)
        var downloaded: [(Int, String)] = []
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, list) in enabled.enumerated() {
                group.addTask {
                    guard let url = URL(string: list.url) else { return (index, nil) }
                    do {
                        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
                        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                              let text = String(data: data, encoding: .utf8) else { return (index, nil) }
                        return (index, text)
                    } catch { return (index, nil) }
                }
            }
            for await (index, text) in group { if let text { downloaded.append((index, text)) } }
        }
        guard !downloaded.isEmpty else { throw BuildError.allListsFailed }
        let conversionStart = Date()
        let output = FilterListConverter.convert(downloaded.sorted { $0.0 < $1.0 }.map(\.1))
        let conversionSeconds = Date().timeIntervalSince(conversionStart)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var chunks: [Chunk] = []
        for content in output.chunks {
            let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
            let id = "angl-" + String(digest.prefix(12))
            let filename = "\(id).json"
            try content.write(to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
            let count = (try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [[String: Any]])?.count ?? 0
            chunks.append(Chunk(id: id, file: filename, rules: count))
        }
        let retainedChunks = Set(chunks.map(\.file))
        let existingFiles = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in existingFiles where file.lastPathComponent.hasPrefix("angl-")
            && file.pathExtension == "json"
            && !retainedChunks.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
        let advancedRulesFile = "advanced.rules"
        let advancedStorageFile = "advanced.storage"
        let advancedIndexFile = "advanced.index"
        try output.advancedRulesText.write(to: dir.appendingPathComponent(advancedRulesFile), atomically: true, encoding: .utf8)
        let ruleLines = output.advancedRulesText.split(whereSeparator: \.isNewline).map(String.init)
        let storage = try FilterRuleStorage(from: ruleLines, for: .safari26, fileURL: dir.appendingPathComponent(advancedStorageFile))
        let engine = try FilterEngine(storage: storage)
        try engine.write(to: dir.appendingPathComponent(advancedIndexFile))

        let manifest = FilterListManifest(
            generated: Date(), skipped: output.skipped, chunks: chunks,
            advancedRules: output.advancedRuleCount, conversionSeconds: conversionSeconds,
            advancedRulesFile: advancedRulesFile, advancedStorageFile: advancedStorageFile,
            advancedIndexFile: advancedIndexFile, sources: enabled.map(\.url),
            failed: enabled.indices.filter { i in !downloaded.contains { $0.0 == i } }.map { enabled[$0].name }
        )
        try JSONFile.write(manifest, to: dir.appendingPathComponent("manifest.json"))
        return manifest
    }

    public enum BuildError: Error { case allListsFailed }
}
