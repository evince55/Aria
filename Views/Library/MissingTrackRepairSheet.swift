import SwiftUI
import UniformTypeIdentifiers

struct MissingTrackRepairSheet: View {
    let track: LocalTrack
    let onReimport: (URL) -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var showingImporter = false

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Track Unavailable")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(tokens.textPrimary)

                Text("The file '\(track.fileName)' (\(track.fileSizeBytes / 1_000_000) MB) is no longer in this app's storage. This can happen if you cleared the app's data or restored from a backup.")
                    .font(.body)
                    .foregroundColor(tokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()

                Button {
                    showingImporter = true
                } label: {
                    Text("Re-import…")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(tokens.accent)
                .accessibilityLabel("Re-import the missing audio file")

                Button(role: .destructive) {
                    onRemove()
                    dismiss()
                } label: {
                    Text("Remove from Library")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Remove the missing track from the library")
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tokens.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    onReimport(url)
                    dismiss()
                }
            }
        }
    }
}
