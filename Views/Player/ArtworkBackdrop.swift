import SwiftUI
import UIKit

/// Apple-Music-style backdrop: heavily blurred artwork + iOS visual-effect blur
/// + a vertical gradient tinted with the track's average color and the
/// current theme's accent.
struct ArtworkBackdrop: View {
    let artworkURL: URL?
    let tokens: DesignTokens

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            tokens.background

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 60)
                    .scaleEffect(1.4)
                    .opacity(0.9)

                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 30)
                    .opacity(0.35)
                    .blendMode(.softLight)
            } else {
                tokens.accent.opacity(0.25)
            }

            LinearGradient(
                colors: [
                    tokens.background.opacity(0.55),
                    tokens.background.opacity(0.85),
                    tokens.background.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .blendMode(.normal)

            LinearGradient(
                colors: [
                    tokens.accent.opacity(0.18),
                    Color.clear,
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
        .task(id: artworkURL) { await load() }
    }

    private func load() async {
        guard let artworkURL else {
            image = nil
            return
        }
        if let cached = ImageMemoryCache.shared.image(for: artworkURL) {
            image = cached
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: artworkURL)
            guard !Task.isCancelled, let img = UIImage(data: data) else { return }
            ImageMemoryCache.shared.store(img, for: artworkURL)
            image = img
        } catch {
            // Silent: backdrop falls back to accent color.
        }
    }
}
