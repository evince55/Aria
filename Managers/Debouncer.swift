import Foundation

/// Debounces a side-effect to fire at most once per `delay` seconds after the
/// last call to `call()`. If a new call arrives before the delay elapses, the
/// pending work item is cancelled and replaced.
///
/// This is intended to coalesce bursts of mutations (e.g., adding 20 tracks to
/// a playlist in a loop) into a single disk write.
final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let action: () -> Void

    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval, queue: DispatchQueue = .main, action: @escaping () -> Void) {
        self.delay = delay
        self.queue = queue
        self.action = action
    }

    func call() {
        schedule(action)
    }

    /// Variant of `call()` that takes the action inline. Useful when the
    /// action's inputs change between calls (e.g., a UI debouncer that
    /// needs to read the current text-field value at flush time).
    func call(_ inlineAction: @escaping () -> Void) {
        schedule(inlineAction)
    }

    /// True between `call()` and the moment the scheduled action fires or
    /// is cancelled. Used by callers that need to suppress reentrant
    /// updates (e.g., syncing an external value into a debounced editor).
    var isPending: Bool { workItem != nil }

    /// Cancels any pending invocation without firing.
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }

    /// Runs the pending action immediately, if any, then clears it.
    func flush() {
        guard let item = workItem, !item.isCancelled else {
            workItem = nil
            return
        }
        item.cancel()
        workItem = nil
        action()
    }

    private func schedule(_ userAction: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            userAction()
            // If a new call() came in after we were scheduled but before
            // we ran, that call would have cancelled us and replaced
            // workItem; our block would not execute. So if we got here,
            // workItem is still us.
            self?.workItem = nil
        }
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
