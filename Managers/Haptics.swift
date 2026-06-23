import UIKit

/// Lightweight haptics helper. Centralised so we can tune intensity in one place
/// and avoid spawning feedback generators on every tap.
enum Haptics {
    static func light() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
    }

    static func medium() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        g.impactOccurred()
    }

    static func soft() {
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.prepare()
        g.impactOccurred()
    }

    static func success() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
    }

    static func warning() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.warning)
    }

    static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }
}
