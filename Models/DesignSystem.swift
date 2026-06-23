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
        static let sectionHeader = Font.system(size: 13, weight: .semibold, design: .default)
            .smallCaps()
    }
}

/// Shadow modifier used by cards and popovers.
extension View {
    func softShadow() -> some View {
        shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 2)
    }
}
