import SwiftUI

/// Download control for a streamed track: download icon → spinner while
/// downloading → filled check when downloaded. Tap downloads; tapping a
/// downloaded track asks to remove. No-op / hidden for local tracks.
struct DownloadButton: View {
    let track: Track
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var confirmRemove = false

    var body: some View {
        if track.isLocal {
            EmptyView()
        } else {
            let state = downloadManager.state(for: track.id)
            Button {
                switch state {
                case .none: Task { await downloadManager.download(track) }
                case .downloading: break
                case .downloaded: confirmRemove = true
                }
            } label: {
                icon(state)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state == .downloading)
            .accessibilityLabel(accessibilityLabel(state))
            .confirmationDialog("Remove this download?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove Download", role: .destructive) { downloadManager.remove(track.id) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func icon(_ state: DownloadState) -> some View {
        switch state {
        case .none:
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .foregroundColor(themeManager.textPrimary)
        case .downloading:
            ProgressView().scaleEffect(0.8)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundColor(themeManager.theme.accentColor)
        }
    }

    private func accessibilityLabel(_ state: DownloadState) -> String {
        switch state {
        case .none: return "Download for offline"
        case .downloading: return "Downloading"
        case .downloaded: return "Downloaded. Tap to remove."
        }
    }
}
