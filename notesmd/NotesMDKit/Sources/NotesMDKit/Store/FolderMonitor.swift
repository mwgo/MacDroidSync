import Foundation

/// Tells when anything in the folder of notes may have changed: a coordinated
/// write by another process or by iCloud, which `NSFilePresenter` hears of,
/// and, for what it misses, a look every `interval` seconds.
public final class FolderMonitor: NSObject, NSFilePresenter {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let onChange: @Sendable () -> Void
    private var timer: Timer?
    private var pending = false
    private let lock = NSLock()

    public init(root: URL, interval: TimeInterval = 10, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = root
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.changed() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        NSFileCoordinator.removeFilePresenter(self)
    }

    deinit {
        timer?.invalidate()
    }

    /// Many changes in a row become one call, half a second after the first.
    public func changed() {
        lock.lock()
        let first = !pending
        pending = true
        lock.unlock()
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pending = false
            self.lock.unlock()
            self.onChange()
        }
    }

    public func presentedSubitemDidChange(at url: URL) { changed() }
    public func presentedSubitemDidAppear(at url: URL) { changed() }
    public func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    public func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        changed()
        completionHandler(nil)
    }
    public func presentedItemDidChange() { changed() }
}
