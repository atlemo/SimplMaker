import Foundation

/// Counts the rebuilds that are running on a background thread, so that quitting can wait for them. The process
/// exit runs the static destructors of the geometry kernel (its thread pool, its type tables) while such a thread
/// may still be inside it, and that crashed the app on exit.
final class KernelActivity: @unchecked Sendable {
    static let shared = KernelActivity()

    private let lock = NSLock()
    private var running = 0
    private var quitting = false

    /// A rebuild is about to start. False when the app is quitting: it must not start.
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !quitting else { return false }
        running += 1
        return true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        running -= 1
    }

    /// Stops new rebuilds from starting. Returns whether one is still running.
    func beginQuit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        quitting = true
        return running > 0
    }

    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return running > 0
    }

    /// Lets rebuilds start again (the quit was cancelled).
    func cancelQuit() {
        lock.lock(); defer { lock.unlock() }
        quitting = false
    }
}
