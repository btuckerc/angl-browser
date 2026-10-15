import Foundation
import WebKit
import AnglCore

/// Block-list conversion and compilation run in a short-lived child (`angl --lists`): compiling
/// peaks at several hundred MB and macOS keeps about 85 MB of it dirty in whichever process did
/// the work. The child writes to the same default rule-list store (same bundle identifier); the
/// app only looks lists up.
enum ListWorker {
    /// Child: `angl --lists <dir> [<lists JSON>]` builds the lists into `dir` when given them,
    /// then compiles every chunk of `dir`'s manifest the store lacks. Errors go to stderr.
    static func main() -> Never {
        let args = Array(CommandLine.arguments.dropFirst(2))
        Task { @MainActor in
            do {
                guard let path = args.first else { throw Failure.usage }
                let dir = URL(fileURLWithPath: path, isDirectory: true)
                if args.count > 1 {
                    let lists = try JSONFile.decoder().decode([FilterList].self, from: Data(args[1].utf8))
                    _ = try await FilterListManifest.build(lists: lists, into: dir)
                }
                guard let m = try JSONFile.read(FilterListManifest.self, from: dir.appendingPathComponent("manifest.json")),
                      let store = WKContentRuleListStore.default() else { throw Failure.noManifest }
                for chunk in m.chunks where (try? await store.contentRuleList(forIdentifier: chunk.id)) == nil {
                    let json = try String(contentsOf: dir.appendingPathComponent(chunk.file), encoding: .utf8)
                    do {
                        _ = try await store.compileContentRuleList(forIdentifier: chunk.id, encodedContentRuleList: json)
                    } catch {
                        throw Failure.compile("\(chunk.file): \(error.localizedDescription)")
                    }
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
        CFRunLoopRun()  // WebKit dispatches to the main run loop; dispatchMain() would crash it
        exit(1)
    }

    /// Parent: runs the child to completion; its error text, nil on success. A child still running
    /// after `timeout` (a stalled download) is terminated.
    static func run(_ dir: URL, lists: [FilterList]? = nil, timeout: TimeInterval = 600) async -> String? {
        var args = ["--lists", dir.path]
        if let lists, let json = try? JSONFile.encoder().encode(lists) { args.append(String(decoding: json, as: UTF8.self)) }
        let arguments = args
        return await Task.detached {
            let p = Process()
            p.executableURL = Bundle.main.executableURL
            p.arguments = arguments
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return error.localizedDescription }
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let output = err.fileHandleForReading.readDataToEndOfFile()  // EOF once the child exits
            p.waitUntilExit()
            watchdog.cancel()
            if p.terminationReason == .uncaughtSignal {
                return p.terminationStatus == SIGTERM ? "list worker timed out" : "list worker crashed (signal \(p.terminationStatus))"
            }
            guard p.terminationStatus != 0 else { return nil }
            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "list worker exited with status \(p.terminationStatus)" : text
        }.value
    }

    private enum Failure: Error, CustomStringConvertible {
        case usage, noManifest
        case compile(String)
        var description: String {
            switch self {
            case .usage: "usage: angl --lists <dir> [<lists JSON>]"
            case .noManifest: "no block-list manifest"
            case .compile(let message): message
            }
        }
    }
}
