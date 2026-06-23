import SwiftUI

struct EqualizerView: View {
    @ObservedObject var playerManager: PlayerManager
    @ObservedObject var themeManager: ThemeManager

    @State private var localBands: [Float]
    @State private var syncWorkItem: DispatchWorkItem?
    @State private var activePreset: EQPreset?

    private var tokens: DesignTokens { themeManager.tokens }

    init(playerManager: PlayerManager, themeManager: ThemeManager) {
        self.playerManager = playerManager
        self.themeManager = themeManager
        _localBands = State(initialValue: playerManager.eqBands)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                VStack(spacing: DS.Spacing.lg) {
                    EQCurveView(bands: localBands, accent: tokens.accent, height: 80)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.top, DS.Spacing.sm)

                    presetsBar
                    eqGrid
                    Spacer()
                    resetButton
                }
                .padding(.bottom, DS.Spacing.xl)
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            localBands = playerManager.eqBands
            syncWorkItem?.cancel()
            syncWorkItem = nil
            activePreset = nil
        }
        .onDisappear {
            cancelPendingSync()
            if localBands != playerManager.eqBands {
                playerManager.applyEQPreset(localBands)
            }
        }
    }

    private var presetsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(EQPreset.allCases) { preset in
                    Button {
                        Haptics.light()
                        applyPreset(preset)
                    } label: {
                        let isActive = activePreset == preset
                        Text(preset.rawValue)
                            .font(DS.Typography.captionStrong)
                            .foregroundColor(isActive ? .white : tokens.textPrimary)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.sm)
                            .background(
                                Capsule()
                                    .fill(isActive
                                          ? AnyShapeStyle(LinearGradient(colors: [tokens.accent, tokens.accent.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                                          : AnyShapeStyle(tokens.surface))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isActive ? Color.clear : tokens.hairline, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
        }
    }

    private var eqGrid: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(0..<10, id: \.self) { i in
                VStack(spacing: DS.Spacing.sm) {
                    Text(String(format: "%+0.0f", localBands[i]))
                        .font(DS.Typography.mono)
                        .foregroundColor(tokens.textSecondary)
                        .frame(height: 14)

                    ThinSlider(
                        value: Binding<Double>(
                            get: { Double(localBands[i]) },
                            set: { newValue in
                                localBands[i] = Float(newValue)
                                activePreset = nil
                                scheduleDebouncedSync()
                            }
                        ),
                        in: -12...12,
                        step: 0.5,
                        accent: tokens.accent,
                        trackHeight: 4,
                        thumbDiameter: 12
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 140, height: 24)

                    Text(frequencyLabel(i))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(tokens.textSecondary)
                        .frame(height: 14)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .frame(height: 200)
    }

    private var resetButton: some View {
        Button {
            Haptics.warning()
            cancelPendingSync()
            localBands = Array(repeating: 0, count: 10)
            activePreset = .flat
            playerManager.resetEQ()
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                Text("Reset to Flat")
                    .font(DS.Typography.bodyEm)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.md)
            .background(
                Capsule()
                    .fill(tokens.accent)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Spacing.xl)
    }

    private func frequencyLabel(_ index: Int) -> String {
        let freq = PlayerManager.eqFrequencies[index]
        if freq >= 1000 { return String(format: "%dk", Int(freq / 1000)) }
        return String(format: "%d", Int(freq))
    }

    private func applyPreset(_ preset: EQPreset) {
        cancelPendingSync()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            localBands = preset.gains
            activePreset = preset
        }
        playerManager.applyEQPreset(preset.gains)
    }

    private func scheduleDebouncedSync() {
        syncWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            playerManager.applyEQPreset(localBands)
        }
        syncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func cancelPendingSync() {
        syncWorkItem?.cancel()
        syncWorkItem = nil
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
