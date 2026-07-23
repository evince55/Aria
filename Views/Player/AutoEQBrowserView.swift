import SwiftUI

/// Searchable catalog of AutoEq correction profiles (8,850 headphones).
/// Search/filter run against the bundled index; tapping a row fetches that
/// profile's tiny ParametricEQ.txt from the AutoEq repo and hands the parsed
/// preset back via `onApply`.
struct AutoEQBrowserView: View {
    /// Called with the fetched, parsed preset; the caller applies it.
    let onApply: (ParametricEQPreset) -> Void
    /// Called when the user prefers a local file (offline / custom profile).
    let onImportFile: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var catalog = AutoEQCatalog()
    @State private var query = ""
    @State private var formFactor: AutoEQCatalogEntry.FormFactor?
    @State private var fetchingID: String?
    @State private var fetchError: String?

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()
                content
            }
            .navigationTitle("AutoEQ Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.light()
                        onImportFile()
                        dismiss()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Import profile from a file instead")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search your headphones")
        }
        .onAppear { catalog.loadIndexIfNeeded() }
        .alert("AutoEQ", isPresented: .init(
            get: { fetchError != nil },
            set: { if !$0 { fetchError = nil } }
        )) {
            Button("OK", role: .cancel) { fetchError = nil }
        } message: {
            Text(fetchError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch catalog.index {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            VStack(spacing: DS.Spacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(tokens.textSecondary)
                Text(error.localizedDescription)
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DS.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let entries):
            catalogList(entries)
        }
    }

    private func catalogList(_ entries: [AutoEQCatalogEntry]) -> some View {
        let filtered = AutoEQCatalog.filter(entries, query: query, formFactor: formFactor)
        return VStack(spacing: 0) {
            formFactorPicker
            if filtered.isEmpty {
                VStack(spacing: DS.Spacing.sm) {
                    Text("No matches")
                        .font(DS.Typography.titleMedium)
                        .foregroundColor(tokens.textPrimary)
                    Text("Try fewer words — e.g. just the model number.")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { entry in
                        row(entry)
                            .listRowBackground(Color.clear)
                    }
                    attribution
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private var formFactorPicker: some View {
        Picker("Form factor", selection: $formFactor) {
            Text("All").tag(AutoEQCatalogEntry.FormFactor?.none)
            ForEach([AutoEQCatalogEntry.FormFactor.overEar, .inEar, .earbud], id: \.self) { f in
                Text(f.label).tag(AutoEQCatalogEntry.FormFactor?.some(f))
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }

    private func row(_ entry: AutoEQCatalogEntry) -> some View {
        Button {
            apply(entry)
        } label: {
            HStack(spacing: DS.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(tokens.textPrimary)
                        .lineLimit(1)
                    Text("measured by \(entry.source)")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if fetchingID == entry.id {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(tokens.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(fetchingID != nil)
    }

    private var attribution: some View {
        Text("Correction profiles from the open-source AutoEq project (jaakkopasanen/AutoEq, MIT), fetched on demand from GitHub.")
            .font(DS.Typography.micro)
            .foregroundColor(tokens.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.md)
    }

    private func apply(_ entry: AutoEQCatalogEntry) {
        guard fetchingID == nil else { return }
        fetchingID = entry.id
        Task {
            defer { fetchingID = nil }
            do {
                let preset = try await catalog.fetchProfile(for: entry)
                Haptics.medium()
                onApply(preset)
                dismiss()
            } catch {
                fetchError = error.localizedDescription
            }
        }
    }
}
