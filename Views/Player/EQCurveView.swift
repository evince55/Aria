import SwiftUI

/// Smooth Catmull-Rom-style curve through the 10 EQ band values, drawn over
/// the slider row. Adds a "premium audio app" feel to the equalizer.
struct EQCurveView: View {
    let bands: [Float]            // length 10, range typically -12...12
    var accent: Color
    var height: CGFloat = 70

    private let range: Float = 12   // symmetric +/- range
    private let points: Int = 60   // sample density

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let midY = h / 2
            let bandCount = max(bands.count - 1, 1)

            ZStack {
                // Center reference line
                Path { p in
                    p.move(to: CGPoint(x: 0, y: midY))
                    p.addLine(to: CGPoint(x: w, y: midY))
                }
                .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                // Filled area below curve
                curvePath(in: CGSize(width: w, height: h))
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.45),
                                accent.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Curve stroke
                curvePath(in: CGSize(width: w, height: h))
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                // Band dots
                ForEach(0..<bands.count, id: \.self) { i in
                    let x = CGFloat(i) / CGFloat(bandCount) * w
                    let norm = CGFloat(max(-range, min(range, bands[i])) / range)
                    let y = midY - norm * (h / 2 - 4)
                    Circle()
                        .fill(accent)
                        .frame(width: 5, height: 5)
                        .position(x: x, y: y)
                }
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: bands)
    }

    private func curvePath(in size: CGSize) -> Path {
        let w = size.width
        let h = size.height
        let midY = h / 2
        let bandCount = max(bands.count - 1, 1)

        let pts: [CGPoint] = (0..<points).map { i in
            let t = Double(i) / Double(points - 1)
            let x = CGFloat(t) * w
            let bandIndex = CGFloat(t) * CGFloat(bandCount)
            let lower = Int(floor(bandIndex))
            let upper = min(lower + 1, bands.count - 1)
            let frac = bandIndex - CGFloat(lower)
            let value = CGFloat(bands[lower]) * (1 - frac) + CGFloat(bands[upper]) * frac
            let norm = max(CGFloat(-range), min(CGFloat(range), value)) / CGFloat(range)
            let y = midY - CGFloat(norm) * (h / 2 - 4)
            return CGPoint(x: x, y: y)
        }

        return Path { p in
            guard let first = pts.first else { return }
            p.move(to: CGPoint(x: first.x, y: midY))
            p.addLine(to: first)
            for i in 1..<pts.count {
                p.addLine(to: pts[i])
            }
            p.addLine(to: CGPoint(x: w, y: midY))
            p.closeSubpath()
        }
    }
}
