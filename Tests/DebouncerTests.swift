import XCTest
@testable import Aria___Music_Browser

final class DebouncerTests: XCTestCase {
    func testCoalescesBursts() {
        let exp = expectation(description: "fires once")
        var fires = 0
        let d = Debouncer(delay: 0.1) { fires += 1; exp.fulfill() }
        for _ in 0..<10 {
            d.call()
        }
        wait(for: [exp], timeout: 1.0)
        // Allow any extra ticks to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(fires, 1)
        }
    }

    func testCancelPreventsFire() {
        let exp = expectation(description: "never fires")
        exp.isInverted = true
        let d = Debouncer(delay: 0.1) { exp.fulfill() }
        d.call()
        d.cancel()
        wait(for: [exp], timeout: 0.5)
    }

    func testFlushFiresImmediately() {
        let exp = expectation(description: "flush fires")
        var fires = 0
        let d = Debouncer(delay: 5.0) { fires += 1; exp.fulfill() }
        d.call()
        d.flush()
        wait(for: [exp], timeout: 0.5)
        XCTAssertEqual(fires, 1)
    }

    func testIsPendingTrueDuringWindow() {
        let d = Debouncer(delay: 0.2) {}
        XCTAssertFalse(d.isPending, "should not be pending before call()")
        d.call()
        XCTAssertTrue(d.isPending, "should be pending immediately after call()")
        d.cancel()
        XCTAssertFalse(d.isPending, "should not be pending after cancel()")
    }

    func testIsPendingFalseAfterFire() {
        let exp = expectation(description: "fires")
        let d = Debouncer(delay: 0.05) { exp.fulfill() }
        d.call()
        XCTAssertTrue(d.isPending)
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(d.isPending, "should not be pending after the action fires")
    }
}
