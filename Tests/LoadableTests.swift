import Testing
@testable import Aria___Music_Browser

@Suite("Loadable")
struct LoadableTests {
    struct TestError: Error, Equatable {
        let message: String
    }

    @Test("default state is idle")
    func defaultState() {
        let loadable: Loadable<Int> = .idle
        #expect(loadable.value == nil)
        #expect(loadable.isLoading == false)
        #expect(loadable.error == nil)
    }

    @Test("loading state exposes isLoading")
    func loadingState() {
        let loadable: Loadable<Int> = .loading
        #expect(loadable.isLoading == true)
        #expect(loadable.value == nil)
        #expect(loadable.error == nil)
    }

    @Test("loaded state exposes value")
    func loadedState() {
        let loadable: Loadable<Int> = .loaded(42)
        #expect(loadable.value == 42)
        #expect(loadable.isLoading == false)
        #expect(loadable.error == nil)
    }

    @Test("failed state exposes error")
    func failedState() {
        let error = TestError(message: "boom")
        let loadable: Loadable<Int> = .failed(error)
        #expect(loadable.error != nil)
        #expect(loadable.value == nil)
        #expect(loadable.isLoading == false)
    }

    @Test("idle and loading are not equal")
    func idleNotEqualLoading() {
        let a: Loadable<Int> = .idle
        let b: Loadable<Int> = .loading
        #expect(a != b)
    }

    @Test("loaded values compare by content")
    func loadedEquality() {
        let a: Loadable<Int> = .loaded(7)
        let b: Loadable<Int> = .loaded(7)
        let c: Loadable<Int> = .loaded(8)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("different cases are not equal")
    func caseInequality() {
        let a: Loadable<Int> = .loaded(1)
        let b: Loadable<Int> = .loading
        #expect(a != b)
    }

    @Test("Sendable conformance compiles for value type")
    func sendableCompileCheck() {
        let loadable: Loadable<[Int]> = .loaded([1, 2, 3])
        Task { @Sendable in
            _ = loadable.value
        }
    }
}
