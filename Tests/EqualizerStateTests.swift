import XCTest
@testable import Aria___Music_Browser

@MainActor
final class EqualizerStateTests: XCTestCase {

    // MARK: - Helpers

    private func makeState(
        initialBands: [Float] = Array(repeating: 0, count: 10),
        debounceDelay: TimeInterval = 0.05,
        onApply: @escaping ([Float]) -> Void = { _ in }
    ) -> (EqualizerState, EQController) {
        let eq = EQController()
        eq.apply(initialBands)
        let state = EqualizerState(
            initialBands: eq.bands,
            debounceDelay: debounceDelay,
            onApply: onApply
        )
        return (state, eq)
    }

    // MARK: - Init

    func test_init_localBandsMatchInitialBands() {
        let bands: [Float] = [1, 2, 3, 4, 5, 0, 0, 0, 0, 0]
        let (state, _) = makeState(initialBands: bands)
        XCTAssertEqual(state.localBands, bands)
    }

    func test_init_isPendingIsFalse() {
        let (state, _) = makeState()
        XCTAssertFalse(state.isPending)
    }

    // MARK: - setBand

    func test_setBand_updatesLocalBandsImmediately() {
        let (state, _) = makeState()
        state.setBand(3, to: 7)
        XCTAssertEqual(state.localBands[3], 7)
    }

    func test_setBand_doesNotCallOnApplyImmediately() {
        var calls: [[Float]] = []
        let (state, _) = makeState(onApply: { calls.append($0) })
        state.setBand(0, to: 5)
        XCTAssertTrue(calls.isEmpty, "onApply should not fire inside the debounce window")
    }

    func test_setBand_callsOnApplyAfterDebounce() {
        let exp = expectation(description: "onApply fires")
        var captured: [Float]?
        let (state, _) = makeState(debounceDelay: 0.05, onApply: { bands in
            captured = bands
            exp.fulfill()
        })
        state.setBand(2, to: 9)
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(captured?[2], 9)
    }

    func test_setBand_burstCoalescesToLastValue() {
        let exp = expectation(description: "onApply fires once")
        var calls: [[Float]] = []
        let (state, _) = makeState(debounceDelay: 0.05, onApply: { bands in
            calls.append(bands)
            if calls.count == 1 { exp.fulfill() }
        })
        state.setBand(0, to: 1)
        state.setBand(0, to: 2)
        state.setBand(0, to: 3)
        wait(for: [exp], timeout: 1.0)
        // Allow any extra ticks to settle.
        try? awaitTask(nanoseconds: 150_000_000)
        XCTAssertEqual(calls.count, 1, "burst should coalesce to a single onApply call")
        XCTAssertEqual(calls.first?[0], 3)
    }

    func test_setBand_marksPendingDuringWindow() {
        let (state, _) = makeState(debounceDelay: 0.5)
        XCTAssertFalse(state.isPending)
        state.setBand(0, to: 1)
        XCTAssertTrue(state.isPending)
    }

    func test_setBand_clearsPendingAfterFire() {
        let exp = expectation(description: "onApply fires")
        let (state, _) = makeState(debounceDelay: 0.05, onApply: { _ in exp.fulfill() })
        state.setBand(0, to: 1)
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(state.isPending)
    }

    // MARK: - syncFromController (Bug A)

    func test_syncFromController_copiesControllerBands() {
        let (state, eq) = makeState(initialBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        eq.apply([0, 0, 0, 0, 0, 6, 0, 0, 0, 0])
        state.syncFromController(eq)
        XCTAssertEqual(state.localBands, eq.bands)
    }

    func test_syncFromController_skipsWhenDebouncePending() {
        // If the user is mid-drag, an external change should not clobber
        // the in-progress value; the next flush will push the right value.
        let (state, eq) = makeState(debounceDelay: 0.5)
        state.setBand(0, to: 4)
        XCTAssertTrue(state.isPending)
        eq.apply([0, 0, 0, 0, 0, 6, 0, 0, 0, 0])
        state.syncFromController(eq)
        XCTAssertEqual(state.localBands[0], 4, "localBands should be untouched while a debounce is pending")
    }

    // MARK: - reset (Bug B)

    func test_reset_zerosBandsAndCallsOnApplyImmediately() {
        let exp = expectation(description: "onApply fires immediately on reset")
        var captured: [Float]?
        let (state, _) = makeState(initialBands: [3, 2, 1, 0, 0, 0, 0, 1, 2, 3], onApply: { bands in
            captured = bands
            exp.fulfill()
        })
        state.reset()
        wait(for: [exp], timeout: 0.5)
        XCTAssertEqual(captured, [Float](repeating: 0, count: 10))
        XCTAssertEqual(state.localBands, [Float](repeating: 0, count: 10))
    }

    func test_reset_duringPendingDebounce_doesNotFireOldBands() {
        // Bug B regression: dragging then tapping Reset within the debounce
        // window must not let a pending flush re-apply the dragged value.
        var calls: [[Float]] = []
        let (state, _) = makeState(debounceDelay: 0.1, onApply: { calls.append($0) })
        state.setBand(0, to: 5)              // schedules a debounced call
        state.reset()                        // zeros, calls onApply immediately with zeros
        try? awaitTask(nanoseconds: 200_000_000)  // wait past the original debounce
        XCTAssertEqual(calls.count, 1, "pending debounce must be cancelled by reset()")
        XCTAssertEqual(calls.first, [Float](repeating: 0, count: 10))
    }

    // MARK: - applyPreset

    func test_applyPreset_setsLocalBandsAndCallsOnApply() {
        let exp = expectation(description: "onApply fires")
        var captured: [Float]?
        let (state, _) = makeState(onApply: { bands in
            captured = bands
            exp.fulfill()
        })
        let preset: [Float] = [6, 5, 3, 0, 0, 0, 0, 0, 0, 0]
        state.applyPreset(preset)
        wait(for: [exp], timeout: 0.5)
        XCTAssertEqual(state.localBands, preset)
        XCTAssertEqual(captured, preset)
    }

    func test_applyPreset_duringPendingDebounce_doesNotFireOldBands() {
        var calls: [[Float]] = []
        let (state, _) = makeState(debounceDelay: 0.1, onApply: { calls.append($0) })
        state.setBand(0, to: 5)
        let preset: [Float] = [1, 2, 3, 4, 5, 0, 0, 0, 0, 0]
        state.applyPreset(preset)
        try? awaitTask(nanoseconds: 200_000_000)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first, preset)
    }

    // MARK: - cancelPending

    func test_cancelPending_dropsScheduledCall() {
        var calls: [[Float]] = []
        let (state, _) = makeState(debounceDelay: 0.1, onApply: { calls.append($0) })
        state.setBand(0, to: 5)
        XCTAssertTrue(state.isPending)
        state.cancelPending()
        XCTAssertFalse(state.isPending)
        try? awaitTask(nanoseconds: 200_000_000)
        XCTAssertTrue(calls.isEmpty, "cancelled debounce must not fire")
    }

    // MARK: - Utility

    private func awaitTask(nanoseconds: UInt64) throws {
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: TimeInterval(nanoseconds) / 1_000_000_000 + 0.5)
    }
}
