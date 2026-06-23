import SwiftUI

/// Custom thin-track + circular-thumb slider. Used in the full-screen player
/// and the equalizer. Keeps the same semantics as `SwiftUI.Slider` so it
/// stays a drop-in replacement.
struct ThinSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var accent: Color = .accentColor
    var trackHeight: CGFloat = 4
    var thumbDiameter: CGFloat = 14
    var onEditingChanged: ((Bool) -> Void)? = nil

    @State private var isDragging: Bool = false

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 0,
        accent: Color = .accentColor,
        trackHeight: CGFloat = 4,
        thumbDiameter: CGFloat = 14,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.accent = accent
        self.trackHeight = trackHeight
        self.thumbDiameter = thumbDiameter
        self.onEditingChanged = onEditingChanged
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return max(0, min(1, (value - range.lowerBound) / span))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let centerY = height / 2
            let thumbX = CGFloat(fraction) * width

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(height: trackHeight)
                    .position(x: width / 2, y: centerY)

                // Filled portion
                Capsule()
                    .fill(accent)
                    .frame(width: max(0, thumbX), height: trackHeight)
                    .position(x: max(0, thumbX) / 2, y: centerY)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: isDragging ? thumbDiameter + 4 : thumbDiameter,
                           height: isDragging ? thumbDiameter + 4 : thumbDiameter)
                    .overlay(
                        Circle()
                            .stroke(accent, lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .position(x: thumbX, y: centerY)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7),
                               value: isDragging)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                            Haptics.selection()
                        }
                        let x = max(0, min(width, drag.location.x))
                        let frac = Double(x / max(width, 1))
                        var newValue = range.lowerBound + frac * (range.upperBound - range.lowerBound)
                        if step > 0 {
                            newValue = (newValue / step).rounded() * step
                        }
                        if newValue != value {
                            value = newValue
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
        }
        .frame(height: max(thumbDiameter + 8, 22))
        .accessibilityElement()
        .accessibilityLabel("Slider")
        .accessibilityValue(Text(String(format: "%.1f", value)))
        .accessibilityAdjustableAction { direction in
            let stepAmount = step > 0 ? step : (range.upperBound - range.lowerBound) / 100
            switch direction {
            case .increment: value = min(range.upperBound, value + stepAmount)
            case .decrement: value = max(range.lowerBound, value - stepAmount)
            @unknown default: break
            }
        }
    }
}
