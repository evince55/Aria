import SwiftUI

/// A real vertical EQ fader driven by `GeometryReader` + `DragGesture`.
///
/// Replaces the old rotated `Slider` (a visual-only `.rotationEffect(-90)`
/// that rendered stubby, overlapping bars and mis-hit-tested). The track is
/// a rounded capsule; an accent fill runs from the 0 dB midline to the
/// current gain, and a thumb marks the value. Dragging maps vertical
/// translation to `EQController.gainRange`, snapped to the nearest 0.5 dB.
///
/// Geometry contract: 0 dB sits at the vertical midpoint, +12 dB at the top,
/// -12 dB at the bottom.
struct EQBandFader: View {
    let gain: Float
    let onChange: (Float) -> Void

    @EnvironmentObject private var themeManager: ThemeManager

    private let range = EQController.gainRange
    private let step: Float = 0.5
    private let trackWidth: CGFloat = 4
    private let thumbSize: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let midY = height / 2
            let centerX = geo.size.width / 2
            let thumbY = yPosition(for: gain, height: height)

            ZStack {
                // Track
                Capsule()
                    .fill(themeManager.dividerColor)
                    .frame(width: trackWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 0 dB reference hairline across the fader
                Rectangle()
                    .fill(themeManager.tokens.hairline)
                    .frame(height: 1)
                    .position(x: centerX, y: midY)

                // Accent fill from the 0 dB midline to the current gain
                Capsule()
                    .fill(themeManager.theme.accentColor)
                    .frame(width: trackWidth,
                           height: abs(thumbY - midY))
                    .position(x: centerX, y: (thumbY + midY) / 2)

                // Thumb
                Circle()
                    .fill(themeManager.theme.accentColor)
                    .frame(width: thumbSize, height: thumbSize)
                    .position(x: centerX, y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newGain = gainValue(forY: value.location.y, height: height)
                        if newGain != gain { onChange(newGain) }
                    }
            )
        }
        // The custom fader replaces a native Slider, so restore VoiceOver's
        // adjustable behavior: announce the gain and step it with swipe up/down.
        // (The caller supplies the per-band frequency label.)
        .accessibilityElement()
        .accessibilityValue(String(format: "%+.1f decibels", gain))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange((gain + step).clamped(to: range))
            case .decrement: onChange((gain - step).clamped(to: range))
            @unknown default: break
            }
        }
    }

    // MARK: - Geometry

    /// Y pixel for a given gain. +12 → top (0), 0 → midpoint, -12 → bottom.
    private func yPosition(for gain: Float, height: CGFloat) -> CGFloat {
        let clamped = gain.clamped(to: range)
        let fraction = CGFloat((clamped - range.lowerBound) /
                               (range.upperBound - range.lowerBound))
        // fraction 0 (-12) → bottom, 1 (+12) → top
        return height - fraction * height
    }

    /// Inverse of `yPosition`, snapped to the nearest `step`.
    private func gainValue(forY y: CGFloat, height: CGFloat) -> Float {
        let clampedY = max(0, min(height, y))
        let fraction = height > 0 ? Float(1 - clampedY / height) : 0.5
        let raw = range.lowerBound +
                  fraction * (range.upperBound - range.lowerBound)
        let snapped = (raw / step).rounded() * step
        return snapped.clamped(to: range)
    }
}
