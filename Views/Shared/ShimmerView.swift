import SwiftUI

/// Animated diagonal shimmer used as a placeholder for loading thumbnails.
struct ShimmerView: View {
    var cornerRadius: CGFloat = 0
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Color.gray.opacity(0.18)

                LinearGradient(
                    colors: [
                        Color.white.opacity(0.0),
                        Color.white.opacity(0.35),
                        Color.white.opacity(0.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: w * 0.6)
                .offset(x: phase * w)
                .blendMode(.plusLighter)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.4
            }
        }
    }
}

#Preview {
    ShimmerView(cornerRadius: 8)
        .frame(width: 200, height: 120)
        .padding()
        .background(.black)
}
