import SwiftUI

struct AddToQueueModifier: ViewModifier {
    @ObservedObject var playerManager: PlayerManager
    let track: Track

    @State private var showConfirmation = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    Haptics.medium()
                    playerManager.addToQueue(track)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                        showConfirmation = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showConfirmation = false
                        }
                    }
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }
            }
            .overlay(alignment: .top) {
                if showConfirmation {
                    confirmationToast
                        .padding(.top, DS.Spacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
    }

    private var confirmationToast: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.green)
            Text("Added to Queue")
                .font(DS.Typography.captionStrong)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .softShadow()
    }
}

extension View {
    func addToQueueGesture(playerManager: PlayerManager, track: Track) -> some View {
        modifier(AddToQueueModifier(playerManager: playerManager, track: track))
    }
}
