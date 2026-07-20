import StoreKit
import SwiftUI

/// The "Aria Pro" paywall sheet: one-time unlock, price from StoreKit,
/// restore, and an honest feature list (shipping Pro features are marked,
/// in-progress ones say "coming soon" — never promise what doesn't exist).
struct AriaProView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var proStore: ProStore
    @Environment(\.dismiss) private var dismiss

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: DS.Spacing.xl) {
                        hero
                        featureList
                        if proStore.isPro {
                            unlockedBadge
                        } else {
                            purchaseButtons
                        }
                        finePrint
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.xl)
                    .padding(.bottom, DS.Spacing.xxl)
                }
            }
            .navigationTitle("Aria Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Store", isPresented: .init(
            get: { proStore.lastError != nil },
            set: { if !$0 { proStore.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { proStore.lastError = nil }
        } message: {
            Text(proStore.lastError ?? "")
        }
    }

    private var hero: some View {
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
                    .frame(width: 84, height: 84)
                    .softShadow()
                Image(systemName: "crown.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(.white)
            }
            Text("Unlock Aria Pro")
                .font(DS.Typography.titleLarge)
                .foregroundColor(tokens.textPrimary)
            Text("One-time purchase. No subscription, ever.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var featureList: some View {
        VStack(spacing: 0) {
            featureRow(icon: "slider.vertical.3", title: "Parametric EQ + AutoEQ import",
                       detail: "Coming soon — correction curves for your exact headphones")
            Divider().background(tokens.hairline).padding(.leading, 56)
            featureRow(icon: "wand.and.stars", title: "Smart playlists",
                       detail: "Coming soon — rule-based playlists that build themselves")
            Divider().background(tokens.hairline).padding(.leading, 56)
            featureRow(icon: "square.and.arrow.down.on.square", title: "M3U import & export",
                       detail: "Coming soon — move playlists in and out freely")
            Divider().background(tokens.hairline).padding(.leading, 56)
            featureRow(icon: "heart.fill", title: "Support independent development",
                       detail: "Pro purchases fund every free feature too")
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(tokens.surface)
        )
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: DS.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(tokens.accent)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.textPrimary)
                Text(detail)
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.md)
    }

    private var purchaseButtons: some View {
        VStack(spacing: DS.Spacing.md) {
            Button {
                Haptics.medium()
                Task { await proStore.purchase() }
            } label: {
                HStack {
                    if proStore.purchaseInFlight {
                        ProgressView().tint(.white)
                    } else {
                        Text(proStore.product.map { "Unlock — \($0.displayPrice)" } ?? "Unlock Aria Pro")
                            .font(DS.Typography.bodyEm)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(tokens.accent)
                .foregroundColor(.white)
                .cornerRadius(DS.Radius.md)
            }
            .disabled(proStore.purchaseInFlight)

            Button {
                Haptics.light()
                Task { await proStore.restore() }
            } label: {
                Text("Restore Purchases")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.accent)
            }
        }
    }

    private var unlockedBadge: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
            Text("Pro unlocked — thank you!")
                .font(DS.Typography.bodyEm)
                .foregroundColor(tokens.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(tokens.surface)
        )
    }

    private var finePrint: some View {
        Text("Aria Pro is a single lifetime unlock tied to your Apple ID. Family Sharing follows your App Store settings. Already purchased? Use Restore Purchases.")
            .font(DS.Typography.micro)
            .foregroundColor(tokens.textSecondary)
            .multilineTextAlignment(.center)
    }
}
