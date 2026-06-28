import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var showClearFavoritesAlert = false
    @State private var showDeletePlaylistsAlert = false
    @State private var showClearCacheAlert = false
    @State private var showClearHistoryAlert = false

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: DS.Spacing.xl) {
                        heroHeader
                        settingsSection
                        advancedSection
                        extrasSection
                        versionFooter
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.lg)
                    .padding(.bottom, 120)
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Clear Search History", isPresented: $showClearHistoryAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Haptics.warning()
                settingsManager.clearSearchHistory()
            }
        } message: {
            Text("This will remove all your recent searches.")
        }
        .alert("Clear Cache", isPresented: $showClearCacheAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Haptics.warning()
                URLCache.shared.removeAllCachedResponses()
            }
        } message: {
            Text("This will clear all cached images and data.")
        }
        .alert("Clear All Favorites", isPresented: $showClearFavoritesAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                Haptics.warning()
                favoritesManager.removeAll()
            }
        } message: {
            Text("This will permanently remove all your favorites. This action cannot be undone.")
        }
        .alert("Delete All Playlists", isPresented: $showDeletePlaylistsAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                Haptics.warning()
                playlistsManager.deleteAll()
            }
        } message: {
            Text("This will permanently delete all playlists. This action cannot be undone.")
        }
    }

    // MARK: - Hero

    private var heroHeader: some View {
        VStack(spacing: DS.Spacing.md) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [tokens.accent, tokens.accent.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)
                    .softShadow()
                Image(systemName: "music.note")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.white)
            }

            VStack(spacing: 4) {
                Text("Aria")
                    .font(DS.Typography.display)
                    .foregroundColor(tokens.textPrimary)
                Text("Music, your way")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.lg)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        MoreCard(title: "Settings", tokens: tokens) {
            VStack(spacing: 0) {
                HStack(spacing: DS.Spacing.md) {
                    iconBadge(systemName: "house", color: tokens.accent)
                    Text("Default Start Page")
                        .font(DS.Typography.body)
                        .foregroundColor(tokens.textPrimary)
                    Spacer()
                    Picker("", selection: $settingsManager.defaultStartTab) {
                        ForEach(DefaultStartTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .tint(tokens.accent)
                    .onChange(of: settingsManager.defaultStartTab) { _ in
                        Haptics.selection()
                        settingsManager.save()
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.md)

                Divider().background(tokens.hairline).padding(.leading, 56)

                Button {
                    Haptics.warning()
                    showClearHistoryAlert = true
                } label: {
                    row(icon: "magnifyingglass", iconColor: tokens.accent, title: "Clear Search History", isButton: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        MoreCard(title: "Advanced", tokens: tokens) {
            VStack(spacing: 0) {
                Button {
                    Haptics.warning()
                    showClearCacheAlert = true
                } label: {
                    row(icon: "trash.slash", iconColor: .orange, title: "Clear Image / Data Cache", isButton: true)
                }
                .buttonStyle(.plain)

                Divider().background(tokens.hairline).padding(.leading, 56)

                Button {
                    Haptics.warning()
                    showClearFavoritesAlert = true
                } label: {
                    row(icon: "heart.slash", iconColor: .red, title: "Clear All Favorites", isButton: true)
                }
                .buttonStyle(.plain)

                Divider().background(tokens.hairline).padding(.leading, 56)

                Button {
                    Haptics.warning()
                    showDeletePlaylistsAlert = true
                } label: {
                    row(icon: "trash", iconColor: .red, title: "Delete All Playlists", isButton: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Extras

    private var extrasSection: some View {
        MoreCard(title: "Extras", tokens: tokens) {
            VStack(spacing: 0) {
                HStack(spacing: DS.Spacing.md) {
                    iconBadge(systemName: "moon.zzz", color: tokens.accent)
                    Text("Sleep Timer")
                        .font(DS.Typography.body)
                        .foregroundColor(tokens.textPrimary)
                    Spacer()
                    Picker("", selection: $settingsManager.sleepTimer) {
                        ForEach(SleepTimerDuration.allCases, id: \.self) { duration in
                            Text(duration.rawValue).tag(duration)
                        }
                    }
                    .tint(tokens.accent)
                    .onChange(of: settingsManager.sleepTimer) { _ in
                        Haptics.selection()
                        settingsManager.save()
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.md)

                Divider().background(tokens.hairline).padding(.leading, 56)

                HStack(spacing: DS.Spacing.md) {
                    iconBadge(systemName: "moon.circle", color: tokens.accent)
                    Text("Dark Mode")
                        .font(DS.Typography.body)
                        .foregroundColor(tokens.textPrimary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { themeManager.isDarkMode },
                        set: { _ in
                            Haptics.light()
                            themeManager.toggleDarkMode()
                        }
                    ))
                    .tint(tokens.accent)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.md)

                Divider().background(tokens.hairline).padding(.leading, 56)

                NavigationLink {
                    themePicker
                } label: {
                    HStack(spacing: DS.Spacing.md) {
                        iconBadge(systemName: "paintpalette", color: tokens.accent)
                        Text("Choose Theme")
                            .font(DS.Typography.body)
                            .foregroundColor(tokens.textPrimary)
                        Spacer()
                        Circle()
                            .fill(tokens.accent)
                            .frame(width: 18, height: 18)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(tokens.textSecondary)
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.md)
                }
            }
        }
    }

    // MARK: - Theme Picker

    private var themePicker: some View {
        ZStack {
            tokens.background.ignoresSafeArea()

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.md), count: 2),
                    spacing: DS.Spacing.md
                ) {
                    ForEach(AppTheme.allThemes) { theme in
                        themeCard(theme)
                    }
                }
                .padding(DS.Spacing.lg)
            }
        }
        .navigationTitle("Themes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func themeCard(_ theme: AppTheme) -> some View {
        let isActive = themeManager.theme.id == theme.id
        return Button {
            Haptics.medium()
            themeManager.selectTheme(theme)
        } label: {
            VStack(spacing: DS.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor, theme.accentColor.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .aspectRatio(1, contentMode: .fit)
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .softShadow()
                Text(theme.name)
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.textPrimary)
            }
            .padding(DS.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(tokens.cardSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                            .stroke(isActive ? theme.accentColor : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Version

    private var versionFooter: some View {
        VStack(spacing: 4) {
            Text("Aria v\(appVersion)")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
            Text("Made with ♥")
                .font(DS.Typography.micro)
                .foregroundColor(tokens.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.lg)
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func row(icon: String, iconColor: Color, title: String, isButton: Bool = false, trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: DS.Spacing.md) {
            iconBadge(systemName: icon, color: iconColor)
            Text(title)
                .font(DS.Typography.body)
                .foregroundColor(tokens.textPrimary)
            Spacer()
            trailing()
            if isButton {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tokens.textSecondary)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.md)
        .contentShape(Rectangle())
    }

    private func iconBadge(systemName: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(color.opacity(0.18))
                .frame(width: 28, height: 28)
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
        }
    }
}

/// Card wrapper used to group More-view sections with a consistent surface.
private struct MoreCard<Content: View>: View {
    let title: String
    let tokens: DesignTokens
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(title: title, tokens: tokens)
                .padding(.horizontal, DS.Spacing.sm)
            content()
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                        .fill(tokens.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                        .stroke(tokens.hairline, lineWidth: 0.5)
                )
        }
    }
}
