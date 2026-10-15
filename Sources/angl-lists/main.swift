import Foundation
import WebKit
import AnglCore

@main
@MainActor
struct AnglLists {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 2 else { throw CLIError.usage }
            let directory = URL(fileURLWithPath: args[1], isDirectory: true)
            switch args[0] {
            case "--out":
                let manifest = try await FilterListManifest.build(lists: FilterList.defaults, into: directory)
                let count = manifest.chunks.reduce(0) { $0 + $1.rules }
                let conversion = String(format: "%.2f", manifest.conversionSeconds)
                print(
                    "Built \(count) Safari rules; skipped \(manifest.skipped); "
                        + "\(manifest.advancedRules) advanced rules; "
                        + "\(manifest.chunks.count) chunks; conversion \(conversion)s"
                )
                let youtubeEntries = try FilterListConverter.advancedEntries(
                    for: URL(string: "https://www.youtube.com/")!,
                    storageURL: directory.appendingPathComponent(manifest.advancedStorageFile),
                    indexURL: directory.appendingPathComponent(manifest.advancedIndexFile)
                )
                let youtubeScriptlets = Set(youtubeEntries.compactMap {
                    $0.kind == .scriptlet ? FilterListConverter.scriptletInvocation($0.content)?.name : nil
                }).sorted()
                print("youtube.com advanced entries: \(youtubeEntries.count); scriptlets: \(youtubeScriptlets.joined(separator: ", "))")
            case "--verify":
                try await verify(directory)
            default: throw CLIError.usage
            }
        } catch {
            fputs("angl-lists: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func verify(_ directory: URL) async throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let manifest = try JSONFile.read(FilterListManifest.self, from: manifestURL) else {
            throw CLIError.missingManifest
        }
        let storeName = "angl-lists-\(UUID().uuidString)"
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(storeName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        guard let store = WKContentRuleListStore(url: storeDirectory) else {
            throw CLIError.storeUnavailable
        }
        let start = Date()
        var failures = 0
        for chunk in manifest.chunks {
            let content = try String(contentsOf: directory.appendingPathComponent(chunk.file), encoding: .utf8)
            do {
                _ = try await store.compileContentRuleList(forIdentifier: chunk.id, encodedContentRuleList: content)
                print("\(chunk.id): ok (\(chunk.rules) rules)")
            } catch {
                failures += 1
                print("\(chunk.id): error: \(error)")
            }
        }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
        print("Verified \(manifest.chunks.count - failures)/\(manifest.chunks.count) chunks in \(elapsed)s")
        if failures > 0 {
            throw CLIError.compileFailed(failures)
        }
    }

    private enum CLIError: Error {
        case usage, missingManifest, storeUnavailable
        case compileFailed(Int)
    }
}
