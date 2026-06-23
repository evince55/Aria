import AVFoundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "AriaApp")

@main
struct AriaApp: App {
    init() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers]
            )
        } catch {
            log.error("Failed to set audio session category: \(error.localizedDescription, privacy: .public)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
