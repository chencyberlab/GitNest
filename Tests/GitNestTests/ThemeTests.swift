import SwiftUI
import XCTest
@testable import GitNest

final class ThemeTests: XCTestCase {
    func testAllPaletteTokensAreValidHex() {
        for palette in allPalettes {
            for appearance in ["light", "dark"] {
                let tokens = appearance == "light" ? palette.light : palette.dark
                let invalid = tokens.invalidColorTokenNames
                XCTAssertEqual(
                    invalid,
                    [],
                    "\(palette.displayName) \(appearance) has invalid tokens: \(invalid.joined(separator: ", "))"
                )
            }
        }
    }

    func testGitNestThemeUsesSystemFallbacksForWindowChrome() {
        let gitNest = ColorThemePalette.gitNest
        XCTAssertNil(gitNest.light.background)
        XCTAssertNil(gitNest.light.surface)
        XCTAssertNil(gitNest.light.elevatedSurface)
        XCTAssertNil(gitNest.light.text)

        XCTAssertNil(gitNest.dark.background)
        XCTAssertNil(gitNest.dark.surface)
        XCTAssertNil(gitNest.dark.elevatedSurface)
        XCTAssertNil(gitNest.dark.text)
    }

    func testThemeCanResolveAllColorsForEveryPalette() {
        for palette in allPalettes {
            let theme = Theme(palette: palette)
            let colors: [Color] = [
                theme.background,
                theme.surface,
                theme.elevatedSurface,
                theme.surfaceMuted,
                theme.text,
                theme.textMuted,
                theme.textTertiary,
                theme.border,
                theme.primary,
                theme.primaryText,
                theme.primarySubtle,
                theme.accent,
                theme.accentSubtle,
                theme.success,
                theme.successSubtle,
                theme.warning,
                theme.warningSubtle,
                theme.error,
                theme.errorSubtle,
                theme.tooltipBackground,
                theme.tooltipText,
                theme.blue,
                theme.teal,
                theme.pink
            ]
            XCTAssertEqual(colors.count, 24, "Unexpected color count for \(palette.displayName)")
        }
    }
}
