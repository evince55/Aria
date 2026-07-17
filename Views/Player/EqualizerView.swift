import SwiftUI

struct EqualizerView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var eq: EQController
    @Environment(\.dismiss) private var dismiss

    @StateObject private var state: EqualizerState

    init() {
        // The view is bound to the env-injected `EQController`, but
        // `init()` runs before env objects are available. The throwaway
        // bands here are immediately replaced on first `onAppear` via
        // `state.syncFromController(eq)`.
        _state = StateObject(wrappedValue: EqualizerState(
            initialBands: Array(repeating: 0, count: 10),
            debounceDelay: 0.4,
            onApply: { _ in }
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    presetsBar
                    eqGrid
                        .frame(maxHeight: .infinity)
                    resetButton
                        .padding(.bottom, DS.Spacing.xl)
                }
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(themeManager.theme.accentColor)
                }
            }
        }
        .onAppear {
            // Wire the live-apply path *before* the first sync. `onApply`
            // was a permanent no-op at init (the env-injected
            // `playerManager` isn't available there); assign it here so
            // drags, presets, and Reset reach the audio while the sheet
            // is open — not only on dismiss.
            state.onApply = { gains in playerManager.applyEQPreset(gains) }
            // First appear with the real env-injected controller.
            // The throwaway bands from `init()` are replaced here.
            state.syncFromController(eq)
        }
        .onChange(of: eq.bands) { _ in
            // External mutation (e.g. another view, future lock-screen
            // handler, programmatic reset) — pull the new bands into
            // the draft state. `syncFromController` is a no-op when a
            // debounce is pending so an in-progress drag is preserved.
            state.syncFromController(eq)
        }
        .onDisappear {
            // Fader drags are debounced (only presets/reset apply
            // synchronously), so dismissing within the debounce window would
            // otherwise drop the last adjustment. Cancel the pending timer and
            // flush the current draft directly if it hasn't reached the audio.
            state.cancelPending()
            if state.localBands != eq.bands {
                playerManager.applyEQPreset(state.localBands)
            }
        }
    }

    private var presetsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(EQPreset.allCases) { preset in
                    let isSelected = state.localBands == preset.gains
                    Button {
                        state.applyPreset(preset.gains)
                    } label: {
                        Text(preset.rawValue)
                            .font(DS.Typography.captionStrong)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.sm)
                            .background(isSelected
                                        ? themeManager.theme.accentColor
                                        : themeManager.surface)
                            .cornerRadius(DS.Radius.lg)
                            .foregroundColor(isSelected
                                             ? .white
                                             : themeManager.textPrimary)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.md)
        }
    }

    private var eqGrid: some View {
        HStack(alignment: .bottom, spacing: 0) {
            dbScaleColumn
            ForEach(0..<10, id: \.self) { i in
                VStack(spacing: DS.Spacing.sm) {
                    Text(gainReadout(state.localBands[i]))
                        .font(DS.Typography.micro)
                        .foregroundColor(themeManager.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(minHeight: 12)

                    EQBandFader(gain: state.localBands[i]) { newGain in
                        state.setBand(i, to: newGain)
                    }
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, DS.Spacing.xs)
                    .accessibilityLabel("\(frequencyLabel(i)) hertz band")

                    Text(frequencyLabel(i))
                        .scaledFont(size: 9, relativeTo: .caption2)
                        .foregroundColor(themeManager.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(minHeight: 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.top, DS.Spacing.lg)
    }

    /// Thin left-edge dB scale (+12 / 0 / -12) aligned to the fader track
    /// height. The hidden placeholders mirror the gain readout and
    /// frequency label so the scale lines up with the fader midline.
    private var dbScaleColumn: some View {
        VStack(spacing: DS.Spacing.sm) {
            Text(" ")
                .font(DS.Typography.micro)
                .frame(minHeight: 12)
                .hidden()

            VStack {
                Text("+12")
                Spacer()
                Text("0")
                Spacer()
                Text("-12")
            }
            .font(DS.Typography.micro)
            .foregroundColor(themeManager.textSecondary)
            .frame(maxHeight: .infinity)

            Text(" ")
                .scaledFont(size: 9, relativeTo: .caption2)
                .frame(minHeight: 12)
                .hidden()
        }
        .padding(.trailing, DS.Spacing.xs)
    }

    /// Signed, unit-suffixed readout with a `-0` guard.
    private func gainReadout(_ g: Float) -> String {
        let v = abs(g) < 0.05 ? 0 : g
        // Faders snap to 0.5 dB, so show one decimal for half-steps; keep
        // whole values compact ("+3 dB", not "+3.0 dB").
        return v == v.rounded()
            ? String(format: "%+.0f dB", v)
            : String(format: "%+.1f dB", v)
    }

    private var resetButton: some View {
        let isFlat = state.localBands.allSatisfy { $0 == 0 }
        return Button {
            state.reset()
        } label: {
            Text("Reset")
                .font(DS.Typography.captionStrong)
                .foregroundColor(themeManager.theme.accentColor)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .stroke(themeManager.tokens.hairline, lineWidth: 1)
                )
        }
        .disabled(isFlat)
        .opacity(isFlat ? 0.4 : 1)
    }

    private func frequencyLabel(_ index: Int) -> String {
        let freq = PlayerManager.eqFrequencies[index]
        if freq >= 1000 { return String(format: "%.0fk", freq / 1000) }
        return String(format: "%.0f", freq)
    }
}

enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case trebleBoost = "Treble Boost"
    case vocal = "Vocal"
    case lounge = "Lounge"
    case rock = "Rock"
    case pop = "Pop"
    case classical = "Classical"

    var id: String { rawValue }

    var gains: [Float] {
        switch self {
        case .flat:        return [ 0,  0,  0,  0,  0,  0,  0,  0,  0,  0]
        case .bassBoost:   return [ 6,  5,  3,  0,  0,  0,  0,  0,  0,  0]
        case .trebleBoost: return [ 0,  0,  0,  0,  0,  0,  3,  5,  6,  6]
        case .vocal:       return [-3, -2,  0,  2,  4,  3,  0, -1, -2, -3]
        case .lounge:      return [ 4,  2,  0,  1,  3,  2,  0,  2,  4,  3]
        case .rock:        return [ 4,  2, -1, -2,  0,  2,  4,  3,  2,  1]
        case .pop:         return [ 0,  2,  3,  1, -1, -2,  0,  2,  4,  3]
        case .classical:   return [ 3,  2,  0, -1, -2,  0,  2,  3,  2,  1]
        }
    }
}
