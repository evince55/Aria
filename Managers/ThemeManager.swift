import SwiftUI
import Combine

@MainActor final class ThemeManager: ObservableObject {
    @Published var theme: AppTheme = .default
    @Published var isDarkMode: Bool = true

    private let settings: SettingsManager

    init(settings: SettingsManager) {
        self.settings = settings
        self.isDarkMode = settings.isDarkMode
        if let t = AppTheme.allThemes.first(where: { $0.id == settings.selectedThemeID }) {
            self.theme = t
        }
    }

    func selectTheme(_ theme: AppTheme) {
        self.theme = theme
        settings.setTheme(theme.id)
    }

    func toggleDarkMode() {
        isDarkMode.toggle()
        settings.isDarkMode = isDarkMode
        settings.save()
    }

    // MARK: - Token API (preferred)

    var tokens: DesignTokens {
        DesignTokens(isDark: isDarkMode, accent: theme.accentColor)
    }

    /// Reasonable default tokens for views that need a `DesignTokens`
    /// value without access to a live `ThemeManager` instance (e.g. a
    /// shared view's default parameter value). Matches `AppTheme.default`
    /// in dark mode, which is the app's default appearance.
    static var fallbackTokens: DesignTokens {
        DesignTokens(isDark: true, accent: AppTheme.default.accentColor)
    }

    // MARK: - Legacy convenience (kept for existing call-sites)

    var background: Color { tokens.background }
    var surface: Color { tokens.surface }
    var textPrimary: Color { tokens.textPrimary }
    var textSecondary: Color { tokens.textSecondary }
    var dividerColor: Color { tokens.dividerColor }
}

/// Strongly-typed design tokens that depend on the current theme & mode.
struct DesignTokens {
    let isDark: Bool
    let accent: Color

    var background: Color {
        isDark ? Color(red: 0.04, green: 0.04, blue: 0.05) : Color(red: 0.98, green: 0.98, blue: 0.99)
    }

    var surface: Color {
        isDark ? Color(white: 0.10) : Color(white: 0.96)
    }

    /// Slightly tinted surface used for "card" backgrounds.
    var cardSurface: Color {
        isDark ? Color(white: 0.12) : Color.white
    }

    var textPrimary: Color {
        isDark ? Color.white : Color(red: 0.07, green: 0.07, blue: 0.08)
    }

    var textSecondary: Color {
        // Light 0.45→0.40 lifts secondary text on the ~0.96 background from
        // ~4.35:1 to ~5.2:1, clearing the WCAG AA 4.5:1 threshold for small
        // text. Dark (0.62 on ~0.10) is already ~6:1.
        isDark ? Color(white: 0.62) : Color(white: 0.40)
    }

    var dividerColor: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    var hairline: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }

    /// Soft accent wash for active rows / pills.
    var accentSubtle: Color {
        accent.opacity(0.18)
    }
}
