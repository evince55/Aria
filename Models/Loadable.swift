import Foundation

/// A typed envelope for async-loaded data. Use this instead of separate
/// `isLoading`, `errorMessage`, `data`, and `hasLoaded` properties — those
/// four booleans can combine into impossible states (e.g. "loading with
/// data and an error"). `Loadable` makes the state machine explicit.
///
/// A typical view body switches on the four cases:
///
/// ```swift
/// switch loadable {
/// case .idle:              emptyState
/// case .loading:           if let cached = loadable.value { resultsList(cached) } else { skeleton }
/// case .loaded(let value): resultsList(value)
/// case .failed(let error): errorView(error)
/// }
/// ```
///
/// `Loadable` is `Sendable` so the cases can be passed across actor
/// boundaries.
enum Loadable<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(Error)

    /// The most-recently loaded value, regardless of current state. Useful
    /// for keeping stale data on screen while a refresh is in flight.
    var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var error: Error? {
        if case .failed(let e) = self { return e }
        return nil
    }
}

extension Loadable: Equatable where Value: Equatable {
    static func == (lhs: Loadable<Value>, rhs: Loadable<Value>) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):
            return true
        case (.loaded(let a), .loaded(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a.localizedDescription == b.localizedDescription
        default:
            return false
        }
    }
}
