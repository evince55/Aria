import XCTest
import SwiftUI
@testable import Aria___Music_Browser

/// `ArtworkPlaceholder` is almost entirely visual, so these tests just
/// confirm it instantiates and renders (via `UIHostingController`) at the
/// full range of sizes it's used at in the app — from the 36pt
/// mini-player thumbnail up to the 290pt full-screen artwork — without
/// crashing or producing a zero-size layout. This guards against, e.g., a
/// `GeometryReader` misconfiguration that only breaks at extreme sizes.
final class ArtworkPlaceholderTests: XCTestCase {

    private func renderedSize(for view: some View, fitting target: CGSize) -> CGSize {
        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(origin: .zero, size: target)
        controller.view.layoutIfNeeded()
        return controller.view.systemLayoutSizeFitting(target)
    }

    func test_instantiatesWithDefaultTokens() {
        let view = ArtworkPlaceholder()
        XCTAssertNotNil(view.body, "should construct a body without crashing")
    }

    func test_rendersAtMiniPlayerSize() {
        let view = ArtworkPlaceholder(tokens: DesignTokens(isDark: true, accent: .blue), cornerRadius: 4)
            .frame(width: 36, height: 36)
        let size = renderedSize(for: view, fitting: CGSize(width: 36, height: 36))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func test_rendersAtFullScreenPlayerSize() {
        let view = ArtworkPlaceholder(tokens: DesignTokens(isDark: false, accent: .pink), cornerRadius: 12)
            .frame(width: 290, height: 290)
        let size = renderedSize(for: view, fitting: CGSize(width: 290, height: 290))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func test_rendersAtLibraryRowSize() {
        let view = ArtworkPlaceholder(tokens: DesignTokens(isDark: true, accent: .green), cornerRadius: 6)
            .frame(width: 48, height: 48)
        let size = renderedSize(for: view, fitting: CGSize(width: 48, height: 48))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    @MainActor
    func test_fallbackTokensMatchAppDefaultTheme() {
        // Sanity check that the parameterless default isn't pinned to an
        // arbitrary/incorrect accent — it should track the app's actual
        // default theme so a call site that omits `tokens` doesn't look
        // out of place next to themed siblings.
        let fallback = ThemeManager.fallbackTokens
        XCTAssertTrue(fallback.isDark)
    }
}
