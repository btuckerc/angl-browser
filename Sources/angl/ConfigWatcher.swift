import Foundation

/// Watches config directories (not files: editors save atomically by renaming) and calls back
/// on the main thread, debounced.
@MainActor
final class ConfigWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private let onChange: @MainActor () -> Void

    init(dirs: [URL], onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        for dir in dirs {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                              queue: .main)
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.schedule() } }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources.append(s)
        }
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.onChange() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    deinit { sources.forEach { $0.cancel() } }
}
