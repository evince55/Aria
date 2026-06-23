import SwiftUI

/// Centralised design tokens. All visual constants should flow from here so
/// the app feels coherent and tweaking the look is a one-file change.
enum DS {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let pill: CGFloat = 9999
    }

    enum Typography {
        static let display = Font.system(size: 28, weight: .bold, design: .default)
        static let titleLarge = Font.system(size: 22, weight: .bold, design: .default)
        static let titleMedium = Font.system(size: 17, weight: .semibold, design: .default)
        static let body = Font.system(size: 15, weight: .regular, design: .default)
        static let bodyEm = Font.system(size: 15, weight: .semibold, design: .default)
        static let caption = Font.system(size: 12, weight: .regular, design: .default)
        static let captionStrong = Font.system(size: 12, weight: .semibold, design: .default)
        static let micro = Font.system(size: 10, weight: .regular, design: .default)
        static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
        static let sectionHeader = Font.system(size: 13, weight: .semibold, design: .default)
            .smallCaps()
    }
}

/// Shadow modifiers you can attach with a single call.
extension View {
    func cardShadow() -> some View {
        shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }

    func floatingShadow() -> some View {
        shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 8)
    }

    func softShadow() -> some View {
        shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 2)
    }

    func miniPlayerShadow() -> some View {
        shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: -2)
    }
}

/// Convenient accent-color opacities so views don't sprinkle magic numbers.
extension Color {
    func subtle() -> some ShapeStyle { self.opacity(0.12) }
    func soft() -> some ShapeStyle { self.opacity(0.25) }
    func strong() -> some ShapeStyle { self.opacity(0.55) }
}
