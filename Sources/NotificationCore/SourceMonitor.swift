import Foundation
import Dispatch
import Darwin

/// Read-only vnode observation with a short polling fallback for missed/coalesced events.
/// All callbacks and descriptor bookkeeping run on the supplied serial queue.
public final class SourceMonitor {
    public enum Reason { case initial, fileChange, fallback }
    private struct Watch {
        let device: dev_t
        let inode: ino_t
        let source: DispatchSourceFileSystemObject
    }
    private let paths: [String]
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let onWake: (Reason) -> Void
    private var watches: [String: Watch] = [:]
    private var timer: DispatchSourceTimer?
    private var running = false
    private var pendingChange: DispatchWorkItem?

    public init(paths: [URL], queue: DispatchQueue, fallbackInterval: TimeInterval = 0.25,
                onWake: @escaping (Reason) -> Void) {
        self.paths = Array(Set(paths.map { $0.standardizedFileURL.path }))
        self.queue = queue; self.interval = max(0.05, fallbackInterval); self.onWake = onWake
    }

    deinit {
        timer?.cancel(); pendingChange?.cancel()
        watches.values.forEach { $0.source.cancel() }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.refreshWatches()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.interval, repeating: self.interval, leeway: .milliseconds(15))
            timer.setEventHandler { [weak self] in self?.wake(.fallback) }
            self.timer = timer; timer.resume()
            self.onWake(.initial)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer?.cancel(); self.timer = nil
            self.pendingChange?.cancel(); self.pendingChange = nil
            self.watches.values.forEach { $0.source.cancel() }; self.watches.removeAll()
        }
    }

    private func changed() {
        guard running, pendingChange == nil else { return }
        // Coalesce a transaction's writes without postponing indefinitely during a busy stream.
        let pending = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChange = nil; self.wake(.fileChange)
        }
        pendingChange = pending
        queue.asyncAfter(deadline: .now() + .milliseconds(10), execute: pending)
    }

    private func wake(_ reason: Reason) {
        guard running else { return }
        refreshWatches()
        onWake(reason)
    }

    private func refreshWatches() {
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
                watches.removeValue(forKey: path)?.source.cancel(); continue
            }
            if let old = watches[path], old.device == info.st_dev, old.inode == info.st_ino { continue }
            watches.removeValue(forKey: path)?.source.cancel()
            let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else { Darwin.close(descriptor); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: queue)
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { Darwin.close(descriptor) }
            watches[path] = Watch(device: opened.st_dev, inode: opened.st_ino, source: source)
            source.resume()
        }
    }
}
