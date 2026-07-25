import Foundation

/// A parametric curve the user has kept — typically the AutoEQ profile for one
/// of their headphones. Wraps `ParametricEQPreset` rather than extending it so
/// the preset stays a pure value (its `==` drives the EQ apply path).
struct SavedEQProfile: Identifiable, Codable, Hashable {
    let id: String
    let preset: ParametricEQPreset
    /// Bumped whenever the profile is re-applied, so the list can surface
    /// recently-used headphones first.
    var lastUsedAt: Date

    var name: String { preset.name }

    init(id: String = UUID().uuidString, preset: ParametricEQPreset, lastUsedAt: Date = Date()) {
        self.id = id
        self.preset = preset
        self.lastUsedAt = lastUsedAt
    }
}
