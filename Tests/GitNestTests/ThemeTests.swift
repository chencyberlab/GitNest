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

    func testInvalidColorTokenNamesRejectsMalformedHex() throws {
        // "#FFFFFG" is 6 chars but ends in a non-hex digit. The old check relied on
        // length + Scanner.scanHexInt64, which stops at the bad char and still
        // succeeds — so a typo'd token slipped through validation. nil fields
        // (system fallbacks) must stay ignored.
        let json = ##"{"accent": "#FFFFFG", "warning": "#12 34", "success": "not-a-color"}"##
        let tokens = try JSONDecoder().decode(ColorThemeTokens.self, from: Data(json.utf8))

        XCTAssertEqual(Set(tokens.invalidColorTokenNames), ["accent", "warning", "success"])
    }

    func testInvalidColorTokenNamesAcceptsEveryValidHexForm() throws {
        // #RGB, #RGBA, #RRGGBB, #RRGGBBAA are all valid and must not be flagged.
        let json = ##"{"accent": "#abc", "warning": "#abcd", "success": "#1A2B3C", "error": "#1A2B3C80"}"##
        let tokens = try JSONDecoder().decode(ColorThemeTokens.self, from: Data(json.utf8))

        XCTAssertEqual(tokens.invalidColorTokenNames, [])
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
