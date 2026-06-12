import SwiftUI

/// GitNest design tokens.
/// Brand colors are fixed; text/surface/border are adaptive so light AND dark
/// modes both read correctly (and selected text inverts properly).
enum Theme {
    // Brand purple (fixed across modes)
    static let purple = Color(hex: 0x7132F5)
    static let purpleDark = Color(hex: 0x5741D8)
    static let purpleAccent = adaptiveColor(light: 0x7132F5, dark: 0xA78BFA)
    static let primaryButton = purpleAccent
    static let primaryButtonText = adaptiveColor(light: 0xF4F1FF, dark: 0x302A3C)
    static let purpleSubtle = adaptiveColor(light: 0x855BFB, dark: 0xA78BFA, lightAlpha: 0.18, darkAlpha: 0.24)

    // Semantic (fixed hues, translucent so they sit on light or dark)
    static let green = adaptiveColor(light: 0x149E61, dark: 0x4ADE9A)
    static let greenSubtle = adaptiveColor(light: 0x149E61, dark: 0x4ADE9A, lightAlpha: 0.18, darkAlpha: 0.18)
    static let danger = adaptiveColor(light: 0xD72D35, dark: 0xFF6B73)
    static let dangerSubtle = adaptiveColor(light: 0xE5484D, dark: 0xFF6B73, lightAlpha: 0.16, darkAlpha: 0.22)
    static let amber = adaptiveColor(light: 0xB7791F, dark: 0xF6C453)
    static let amberSubtle = adaptiveColor(light: 0xD69E2E, dark: 0xF6C453, lightAlpha: 0.18, darkAlpha: 0.20)

    // Extra hues so each change-summary status group reads as a distinct color.
    static let blue = adaptiveColor(light: 0x2563EB, dark: 0x7AA2F7)
    static let teal = adaptiveColor(light: 0x0F8A8A, dark: 0x4FD6C9)
    static let pink = adaptiveColor(light: 0xC2185B, dark: 0xF472B6)

    // Adaptive text / surfaces — system semantic colors flip with light/dark.
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = adaptiveColor(light: 0x5E5968, dark: 0xCAC6D4)
    static let textTertiary = adaptiveColor(light: 0x777381, dark: 0xA29DAD)
    static let border = adaptiveColor(light: 0xD7D3DD, dark: 0x56515F, lightAlpha: 0.75, darkAlpha: 0.85)
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let surfaceMuted = adaptiveColor(light: 0xF5F3F7, dark: 0x28262C)
    static let tooltipBackground = adaptiveColor(light: 0xFFFFFF, dark: 0x1F1D24)
    static let tooltipText = adaptiveColor(light: 0x2F2A38, dark: 0xF2F0F8)

    // Radii: 12px buttons, 8/6px small controls.
    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
    static let radiusMicro: CGFloat = 6

    // Fonts — system fonts for display and UI typography.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }

    private static func adaptiveColor(light: UInt, dark: UInt, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.isDarkMode ? dark : light,
                    alpha: appearance.isDarkMode ? darkAlpha : lightAlpha)
        })
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

private extension NSColor {
    convenience init(hex: UInt, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

private extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Primary purple CTA with a 12px radius and subtle shadow.
struct PrimaryPurpleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    // Nested View so the style can read `isEnabled` and visibly grey out when the
    // button is `.disabled(...)` — custom ButtonStyles don't dim on their own.
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryButtonText)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(Theme.primaryButton.opacity(configuration.isPressed ? 0.82 : 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .shadow(color: .black.opacity(isEnabled ? 0.03 : 0), radius: 12, y: 4)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}

/// Subtle secondary button.
struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(Theme.surfaceMuted.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Small square icon chip used in repo rows; tint defaults to purple.
struct IconChipButtonStyle: ButtonStyle {
    var tint: Color = Theme.purpleAccent
    var fill: Color = Theme.purpleSubtle
    var isHovered: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 26)
            .background(fill.opacity(configuration.isPressed ? 0.65 : (isHovered ? 1 : 0.9)))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(tint.opacity(isHovered ? 0.55 : 0.22), lineWidth: 1))
            .contentShape(Rectangle())
    }
}
