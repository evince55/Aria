import Foundation
import Combine

/// Owns the local "draft" band values used by `EqualizerView` and bridges
/// them to the global `EQController` via a debounced apply callback.
///
/// The view holds one of these as a `@StateObject` and reads/writes
/// `localBands` directly. Slider drags update `localBands` immediately
/// (so the UI is responsive) and schedule a debounced flush. Preset and
/// reset operations apply synchronously and cancel any pending flush.
///
/// Two bugs that lived inline in `EqualizerView` are fixed here:
///
/// - **Bug A** — `localBands` no longer drifts from `eq.bands` after an
///   external change. Call `syncFromController()` from the view's
///   `.onChange(of: eq.bands)`; this no-ops if a debounce is already
///   pending (the user's in-progress drag will push the right value on
///   flush).
/// - **Bug B** — Reset no longer races the debounce. `reset()` cancels
///   the pending work item before zeroing and applying, so the dragged
///   value is not re-applied after the user taps Reset.
@MainActor
final class EqualizerState: ObservableObject {

    @Published private(set) var localBands: [Float]

    /// Settable so the view can wire the env-injected `PlayerManager` at
    /// `.onAppear` (it isn't available at `init()`). Defaults to the
    /// closure passed at init.
    var onApply: ([Float]) -> Void
    private let debouncer: Debouncer

    /// True between `setBand` and the moment the debounced flush runs (or
    /// is cancelled). Suppresses external syncs so an in-progress drag
    /// isn't clobbered by an unrelated `eq.bands` change.
    var isPending: Bool { debouncer.isPending }

    init(
        initialBands: [Float],
        debounceDelay: TimeInterval = 0.4,
        onApply: @escaping ([Float]) -> Void
    ) {
        self.onApply = onApply
        self.localBands = initialBands
        // The init action is a placeholder — we always use the inline
        // `call(_:)` form so the closure can read the latest `localBands`
        // at flush time (see Bug B).
        self.debouncer = Debouncer(delay: debounceDelay) {}
    }

    // MARK: - Slider drag

    func setBand(_ index: Int, to value: Float) {
        guard index >= 0, index < localBands.count else { return }
        localBands[index] = value
        scheduleFlush()
    }

    // MARK: - External sync (Bug A)

    /// Copies `controller.bands` into `localBands`. Skips the copy when
    /// a debounced flush is pending so the user's in-progress drag
    /// isn't clobbered. The controller is passed in (rather than held)
    /// so the view can wire the env-injected instance at sync time.
    func syncFromController(_ controller: EQController) {
        guard !isPending else { return }
        localBands = controller.bands
    }

    // MARK: - Reset / preset (Bug B)

    /// Zeros all bands and applies immediately. Cancels any pending
    /// debounced flush so the dragged value is not re-applied.
    func reset() {
        debouncer.cancel()
        localBands = Array(repeating: 0, count: localBands.count)
        onApply(localBands)
    }

    /// Replaces `localBands` with `gains` and applies immediately.
    /// Cancels any pending debounced flush.
    func applyPreset(_ gains: [Float]) {
        debouncer.cancel()
        localBands = gains
        onApply(localBands)
    }

    // MARK: - Cancellation

    func cancelPending() {
        debouncer.cancel()
    }

    // MARK: - Internals

    private func scheduleFlush() {
        // Inline action reads `localBands` at *flush* time, not at
        // schedule time. If a Reset or preset arrives in the debounce
        // window and the work item somehow still runs, it would push
        // the latest values — which is exactly what we want.
        debouncer.call { [weak self] in
            guard let self else { return }
            self.onApply(self.localBands)
        }
    }
}
