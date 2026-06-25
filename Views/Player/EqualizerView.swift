import SwiftUI

struct EqualizerView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var eq: EQController

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
                    Spacer()
                    resetButton
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
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
            state.cancelPending()
            // If the user dismissed mid-drag, push the latest value now
            // so it isn't lost.
            if state.localBands != eq.bands {
                playerManager.applyEQPreset(state.localBands)
            }
        }
    }

    private var presetsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(EQPreset.allCases) { preset in
                    Button {
                        state.applyPreset(preset.gains)
                    } label: {
                        Text(preset.rawValue)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(themeManager.dividerColor)
                            .cornerRadius(16)
                            .foregroundColor(themeManager.textPrimary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var eqGrid: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(0..<10, id: \.self) { i in
                VStack(spacing: 8) {
                    Text(String(format: "%.0f", state.localBands[i]))
                        .font(.caption2)
                        .foregroundColor(themeManager.textSecondary)
                        .frame(height: 12)

                    Slider(value: Binding<Double>(
                        get: { Double(state.localBands[i]) },
                        set: { newValue in
                            state.setBand(i, to: Float(newValue))
                        }
                    ), in: -12...12, step: 0.5)
                    .tint(themeManager.theme.accentColor)
                    .rotationEffect(.degrees(-90))
                    .frame(height: 140)
                    .padding(.horizontal, 2)

                    Text(frequencyLabel(i))
                        .font(.system(size: 9))
                        .foregroundColor(themeManager.textSecondary)
                        .frame(height: 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .frame(height: 240)
    }

    private var resetButton: some View {
        Button {
            state.reset()
        } label: {
            Text("Reset")
                .font(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(themeManager.dividerColor)
                .cornerRadius(12)
                .foregroundColor(themeManager.textPrimary)
        }
        .padding(.horizontal, 24)
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
