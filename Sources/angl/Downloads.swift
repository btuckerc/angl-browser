import AnglCore
import AppKit
import WebKit

struct DownloadItem: Codable, Equatable {
    enum State: String, Codable { case running, done, failed, cancelled }
    var id: String
    var filename: String
    var url: String
    var path: String
    var received: Int64
    var total: Int64
    var state: State
    var date: Date
}

/// WKDownload bookkeeping: saves straight into the downloads folder (no prompt), keeps a log.
@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    private let paths: Paths
    private(set) var items: [DownloadItem]
    private var live: [ObjectIdentifier: (id: String, download: WKDownload, observer: NSKeyValueObservation?)] = [:]
    private var lastPost = Date.distantPast

    init(paths: Paths) {
        self.paths = paths
        var items = (try? JSONFile.read([DownloadItem].self, from: paths.downloadsFile)) ?? []
        for i in items.indices where items[i].state == .running { items[i].state = .failed }
        self.items = items
    }

    var active: [DownloadItem] { items.filter { $0.state == .running } }

    func adopt(_ download: WKDownload) {
        download.delegate = self
    }

    private func folder() -> URL {
        let raw = Browser.shared.settings.downloads.folder
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = folder()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clean = suggestedFilename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let name = clean.isEmpty ? "download" : clean
        var dest = dir.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        let id = UUID().uuidString
        items.insert(DownloadItem(id: id, filename: dest.lastPathComponent,
                                  url: download.originalRequest?.url?.absoluteString ?? "",
                                  path: dest.path, received: 0, total: max(0, response.expectedContentLength),
                                  state: .running, date: Date()), at: 0)
        let observer = download.progress.observe(\.completedUnitCount) { [weak self] p, _ in
            let done = p.completedUnitCount, total = p.totalUnitCount
            Task { @MainActor in self?.progress(id: id, received: done, total: total) }
        }
        live[ObjectIdentifier(download)] = (id, download, observer)
        changed(force: true)
        return dest
    }

    private func progress(id: String, received: Int64, total: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].received = received
        if total > 0 { items[i].total = total }
        changed(force: false)
    }

    func downloadDidFinish(_ download: WKDownload) { finish(download, .done) }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        finish(download, (error as? URLError)?.code == .cancelled ? .cancelled : .failed)
    }

    private func finish(_ download: WKDownload, _ state: DownloadItem.State) {
        guard let entry = live.removeValue(forKey: ObjectIdentifier(download)),
              let i = items.firstIndex(where: { $0.id == entry.id }) else { return }
        items[i].state = state
        if state == .done {
            items[i].received = max(items[i].received, items[i].total)
            // Bounce the Downloads stack like Safari does.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: items[i].path)
        }
        changed(force: true)
    }

    func cancel(_ id: String) {
        live.values.first { $0.id == id }?.download.cancel { _ in }
    }

    func reveal(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func open(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), item.state == .done else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
        changed(force: true)
    }

    private func changed(force: Bool) {
        guard force || Date().timeIntervalSince(lastPost) > 0.25 else { return }
        lastPost = Date()
        if force { try? JSONFile.write(Array(items.prefix(200)), to: paths.downloadsFile) }
        Browser.shared.post(.anglDownloads)
    }
}
