import Foundation
import Combine
import SwiftUI

/// The set of modal sheets the app can present. Identifiable so it can be
/// driven by SwiftUI's `.sheet(item:)` modifier.
enum AppSheet: String, Identifiable {
    case equalizer
    case addToPlaylist
    case queue

    var id: String { rawValue }
}

/// Single source of truth for what modal sheet the player is currently
/// presenting. Replaces the three `@State private var show* = false`
/// booleans that FullScreenPlayerView used to thread (one per sheet,
/// with a separate `.sheet(isPresented:)` modifier per sheet).
///
/// Views that want to present a sheet set `nav.presentedSheet = .equalizer`;
/// the sheet modifier in `FullScreenPlayerView` switches on the enum to
/// choose the content. Views that want to dismiss a sheet set it to `nil`.
///
/// The coordinator owns *what* is presented; the views still own *how*
/// (the `.sheet` modifier and its presentation style).
@MainActor
final class NavigationCoordinator: ObservableObject {
    @Published var presentedSheet: AppSheet?
}
