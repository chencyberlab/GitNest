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

    func testCustomWindowChromeDetection() {
        // The default GitNest theme intentionally follows the OS, so it must report
        // no custom chrome — the title bar stays system black/white.
        XCTAssertFalse(Theme(palette: .gitNest).hasCustomWindowChrome)

        // Every third-party palette must define a window background in both
        // appearances so the title bar can be recoloured to match the content
        // area. A palette that ships half-themed would leave the bar inconsistent
        // with the rest of the window, so this guards against that regression.
        let custom = allPalettes.filter { $0.id != ColorThemePalette.gitNest.id }
        XCTAssertFalse(custom.isEmpty, "Expected at least one third-party palette to test")
        for palette in custom {
            let theme = Theme(palette: palette)
            XCTAssertTrue(theme.hasCustomWindowChrome,
                          "\(palette.displayName) should report custom window chrome")
            XCTAssertNotNil(palette.light.background,
                            "\(palette.displayName) light.background must be set to theme the title bar")
            XCTAssertNotNil(palette.dark.background,
                            "\(palette.displayName) dark.background must be set to theme the title bar")
        }
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

    /// `surfaceMuted` is the fill used for row hover, search fields, and the Output
    /// panel. If it ever aliases `surface` (the old `fromPlanned` default), those
    /// fills turn invisible — the bug where GitNest showed hover but Nord didn't.
    /// Every palette must define a `surfaceMuted` that is a visible step from
    /// `surface` in both appearances.
    func testSurfaceMutedIsAVisibleStepFromSurface() {
        for palette in allPalettes {
            for (appearance, tokens) in [("light", palette.light), ("dark", palette.dark)] {
                guard let surfaceHex = tokens.surface,
                      let mutedHex = tokens.surfaceMuted else {
                    // nil = OS system fallback (the built-in GitNest theme), which is
                    // intentionally OS-following and out of scope for this check.
                    continue
                }
                let distance = Self.perceptualDistance(Self.rgb(surfaceHex), Self.rgb(mutedHex))
                XCTAssertGreaterThanOrEqual(
                    distance, 7.5,
                    "\(palette.displayName) \(appearance): surfaceMuted (\(mutedHex)) is too close to surface (\(surfaceHex)) — hover/search/log fills would be invisible. Expected ≥ 7.5, got \(distance)."
                )
            }
        }
    }

    // MARK: Hex distance helpers

    /// Parse `#RGB`/`#RRGGBB`/`#RRGGBBAA` to an (r,g,b) triple in 0–255. Mirrors
    /// the production parser so the test evaluates the same strings the app does.
    private static func rgb(_ hex: String) -> (Double, Double, Double) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&v)
        switch cleaned.count {
        case 3:
            return (Double((v >> 8) & 0xF) * 17, Double((v >> 4) & 0xF) * 17, Double(v & 0xF) * 17)
        case 4:
            return (Double((v >> 12) & 0xF) * 17,
                    Double((v >> 8) & 0xF) * 17,
                    Double((v >> 4) & 0xF) * 17)
        case 6:
            return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
        case 8:
            return (Double((v >> 24) & 0xFF), Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF))
        default:
            return (0, 0, 0)
        }
    }

    /// Cheap perceptual proxy: mean of the per-channel absolute deltas. A value of
    /// 6+ reliably reads as a visible wash on screen without being so strong it
    /// competes with `surface`. Kept simple and dependency-free on purpose.
    private static func perceptualDistance(_ a: (Double, Double, Double),
                                           _ b: (Double, Double, Double)) -> Double {
        let dr = abs(a.0 - b.0), dg = abs(a.1 - b.1), db = abs(a.2 - b.2)
        return (dr + dg + db) / 3.0
    }

    /// `tooltipBackground` used to alias `elevatedSurface` in every `fromPlanned`
    /// palette, so tooltips had the same fill as raised cards. Even with a shadow
    /// and border, a tooltip should read as a distinct floating layer. Every
    /// palette that defines both tokens must keep them perceptibly separate.
    func testTooltipBackgroundIsDistinctFromElevatedSurface() {
        for palette in allPalettes {
            for (appearance, tokens) in [("light", palette.light), ("dark", palette.dark)] {
                guard let elevatedHex = tokens.elevatedSurface,
                      let tooltipHex = tokens.tooltipBackground else {
                    continue
                }
                let distance = Self.perceptualDistance(Self.rgb(elevatedHex), Self.rgb(tooltipHex))
                XCTAssertGreaterThanOrEqual(
                    distance, 3.0,
                    "\(palette.displayName) \(appearance): tooltipBackground (\(tooltipHex)) is too close to elevatedSurface (\(elevatedHex)) — tooltips will read as cards instead of floating layers. Expected ≥ 3.0, got \(distance)."
                )
            }
        }
    }

    /// `primarySubtle` and `accentSubtle` used to both alias `selection` (a neutral
    /// gray) in `fromPlanned`, even when `primary` and `accent` were different colors.
    /// That meant a primary button and an accent badge shared the same subtle fill,
    /// losing the tint that ties them to their respective hues. When primary and
    /// accent differ, their subtle variants must also differ.
    func testAccentSubtleIsDistinctFromPrimarySubtleWhenColorsDiffer() {
        for palette in allPalettes {
            for (appearance, tokens) in [("light", palette.light), ("dark", palette.dark)] {
                guard let primaryHex = tokens.primary,
                      let accentHex = tokens.accent,
                      let primarySubtleHex = tokens.primarySubtle,
                      let accentSubtleHex = tokens.accentSubtle else {
                    continue
                }
                let primaryDistance = Self.perceptualDistance(Self.rgb(primaryHex), Self.rgb(accentHex))
                let subtleDistance = Self.perceptualDistance(Self.rgb(primarySubtleHex), Self.rgb(accentSubtleHex))
                // If primary and accent are already the same color (GitNest's unified
                // brand design), their subtle variants can match — that's intentional.
                // But if primary and accent differ, the subtle fills must differ too.
                if primaryDistance >= 6.0 {
                    XCTAssertGreaterThanOrEqual(
                        subtleDistance, 3.0,
                        "\(palette.displayName) \(appearance): primarySubtle (\(primarySubtleHex)) and accentSubtle (\(accentSubtleHex)) are too close even though primary (\(primaryHex)) and accent (\(accentHex)) differ. The subtle fills should carry their respective tints. Expected ≥ 3.0, got \(subtleDistance)."
                    )
                }
            }
        }
    }
}
