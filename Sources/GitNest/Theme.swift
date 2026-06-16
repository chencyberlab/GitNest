import SwiftUI

/// Raw token values for one appearance (light or dark). All colour strings are
/// HEX (e.g. "#7132F5" or "#7132F580" for 50 % alpha, in #RRGGBBAA order).
/// `nil` means "fall back to the system semantic colour" — used by the built-in
/// GitNest theme for window background, surface and label text so it continues
/// to follow the OS exactly.
struct ColorThemeTokens: Codable, Hashable, Sendable {
    let background: String?
    let surface: String?
    let elevatedSurface: String?
    let surfaceMuted: String?
    let text: String?
    let textMuted: String?
    let textTertiary: String?
    let border: String?
    let primary: String?
    let primaryText: String?
    let primarySubtle: String?
    let accent: String?
    let accentSubtle: String?
    let success: String?
    let successSubtle: String?
    let warning: String?
    let warningSubtle: String?
    let error: String?
    let errorSubtle: String?
    let tooltipBackground: String?
    let tooltipText: String?
    let blue: String?
    let teal: String?
    let pink: String?
}

/// A named colour scheme with separate light and dark token sets.
struct ColorThemePalette: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let light: ColorThemeTokens
    let dark: ColorThemeTokens

    static func palette(for id: String) -> ColorThemePalette? {
        allPalettes.first { $0.id == id }
    }
}

/// Resolved theme exposed through the SwiftUI environment. Colours are adaptive:
/// they automatically flip between the palette's light and dark tokens based on
/// the current appearance.
struct Theme: EnvironmentKey {
    static let defaultValue = Theme(palette: .gitNest)

    let palette: ColorThemePalette

    // MARK: Surfaces
    var background: Color { adaptive(\.background, system: .windowBackgroundColor) }
    var surface: Color { adaptive(\.surface, system: .windowBackgroundColor) }
    var elevatedSurface: Color { adaptive(\.elevatedSurface, system: .windowBackgroundColor) }
    var surfaceMuted: Color { adaptive(\.surfaceMuted) }

    // MARK: Text
    var text: Color { adaptive(\.text, system: .labelColor) }
    var textMuted: Color { adaptive(\.textMuted) }
    var textTertiary: Color { adaptive(\.textTertiary) }

    // MARK: Borders
    var border: Color { adaptive(\.border) }

    // MARK: Primary / accent
    var primary: Color { adaptive(\.primary) }
    var primaryText: Color { adaptive(\.primaryText) }
    var primarySubtle: Color { adaptive(\.primarySubtle) }
    var accent: Color { adaptive(\.accent) }
    var accentSubtle: Color { adaptive(\.accentSubtle) }

    // MARK: Semantic status
    var success: Color { adaptive(\.success) }
    var successSubtle: Color { adaptive(\.successSubtle) }
    var warning: Color { adaptive(\.warning) }
    var warningSubtle: Color { adaptive(\.warningSubtle) }
    var error: Color { adaptive(\.error) }
    var errorSubtle: Color { adaptive(\.errorSubtle) }

    // MARK: Extra hues
    var blue: Color { adaptive(\.blue) }
    var teal: Color { adaptive(\.teal) }
    var pink: Color { adaptive(\.pink) }

    // MARK: Tooltips
    var tooltipBackground: Color { adaptive(\.tooltipBackground) }
    var tooltipText: Color { adaptive(\.tooltipText) }

    // MARK: Fixed design tokens (not part of the selectable colour scheme)
    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
    static let radiusMicro: CGFloat = 6

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }

    // MARK: Resolution

    /// `NSColor(name:dynamicProvider:)` is relatively expensive and the theme's
    /// properties are read on every view render. Cache the resolved `Color` per
    /// (palette, token) so the dynamic provider is created only once.
    private static let colorCacheLock = NSLock()
    private static var colorCache: [ColorCacheKey: Color] = [:]

    private struct ColorCacheKey: Hashable {
        let paletteID: String
        let keyPath: KeyPath<ColorThemeTokens, String?>
    }

    private func adaptive(_ keyPath: KeyPath<ColorThemeTokens, String?>,
                          system fallback: NSColor = .clear) -> Color {
        let cacheKey = ColorCacheKey(paletteID: palette.id, keyPath: keyPath)
        Theme.colorCacheLock.lock()
        if let cached = Theme.colorCache[cacheKey] {
            Theme.colorCacheLock.unlock()
            return cached
        }
        Theme.colorCacheLock.unlock()

        let color = Color(nsColor: NSColor(name: nil) { appearance in
            let tokens = appearance.isDarkMode ? self.palette.dark : self.palette.light
            guard let hex = tokens[keyPath: keyPath] else {
                switch keyPath {
                case \.background, \.surface, \.elevatedSurface:
                    return NSColor.windowBackgroundColor
                case \.text:
                    return NSColor.labelColor
                default:
                    return fallback
                }
            }
            return NSColor(hex: hex)
        })

        Theme.colorCacheLock.lock()
        Theme.colorCache[cacheKey] = color
        Theme.colorCacheLock.unlock()
        return color
    }
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[Theme.self] }
        set { self[Theme.self] = newValue }
    }
}

// MARK: - Button styles

/// Primary CTA with a 12px radius and subtle shadow. Tint comes from the
/// current theme's `primary` / `primaryText` tokens.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    // Nested View so the style can read `isEnabled` and the current theme and
    // visibly grey out when the button is `.disabled(...)` — custom
    // ButtonStyles don't dim on their own.
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.theme) private var theme

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(theme.primary.opacity(configuration.isPressed ? 0.82 : 1))
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
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.theme) private var theme

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .background(theme.surfaceMuted.opacity(configuration.isPressed ? 0.6 : 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
    }
}

/// Small square icon chip used in repo rows. Pass `nil` for tint/fill to fall
/// back to the current theme's accent colour.
struct IconChipButtonStyle: ButtonStyle {
    var tint: Color?
    var fill: Color?
    var isHovered: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint, fill: fill, isHovered: isHovered)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        let fill: Color?
        let isHovered: Bool
        // Custom ButtonStyles don't dim on their own, so read `isEnabled` and grey
        // out when a row marks the action `.disabled(...)` while it's busy — without
        // this the buttons stop responding but still look fully active.
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.theme) private var theme

        var body: some View {
            let resolvedTint = tint ?? theme.accent
            let resolvedFill = fill ?? theme.accentSubtle
            configuration.label
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(resolvedTint)
                .frame(width: 28, height: 26)
                .background(resolvedFill.opacity(configuration.isPressed ? 0.65 : (isHovered ? 1 : 0.9)))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .strokeBorder(resolvedTint.opacity(isHovered ? 0.55 : 0.22), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - HEX helpers

extension Color {
    init(hex: String) {
        let components = parseHexColor(hex) ?? (red: 0, green: 0, blue: 0, alpha: 1)
        self.init(.sRGB,
                  red: components.red,
                  green: components.green,
                  blue: components.blue,
                  opacity: components.alpha)
    }

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
    convenience init(hex: String) {
        let components = parseHexColor(hex) ?? (red: 0, green: 0, blue: 0, alpha: 1)
        self.init(srgbRed: CGFloat(components.red),
                  green: CGFloat(components.green),
                  blue: CGFloat(components.blue),
                  alpha: CGFloat(components.alpha))
    }
}

/// Parses a hex colour string in `#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA` form.
/// Returns `nil` when the string is empty or not a recognised hex format.
private func parseHexColor(_ hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    guard !cleaned.isEmpty else { return nil }
    var value: UInt64 = 0
    // Every character must be a hex digit: scanHexInt64 alone stops at the first
    // non-hex char and still reports success, so "FFFFFG" would slip through the
    // length check and parse as a partial colour instead of being rejected.
    guard cleaned.allSatisfy(\.isHexDigit),
          [3, 4, 6, 8].contains(cleaned.count),
          Scanner(string: cleaned).scanHexInt64(&value) else {
        return nil
    }

    let r, g, b, a: UInt64
    switch cleaned.count {
    case 3:
        (r, g, b, a) = ((value >> 8) * 17, (value >> 4 & 0xF) * 17, (value & 0xF) * 17, 255)
    case 4:
        (r, g, b, a) = ((value >> 12) * 17, (value >> 8 & 0xF) * 17, (value >> 4 & 0xF) * 17, (value & 0xF) * 17)
    case 6:
        (r, g, b, a) = (value >> 16, value >> 8 & 0xFF, value & 0xFF, 255)
    case 8:
        (r, g, b, a) = (value >> 24, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
    default:
        return nil
    }

    return (Double(r) / 255, Double(g) / 255, Double(b) / 255, Double(a) / 255)
}

extension ColorThemeTokens {
    /// Names of colour-token fields whose value is non-`nil` but not a valid hex
    /// colour. `nil` values (system fallbacks) are ignored.
    var invalidColorTokenNames: [String] {
        Mirror(reflecting: self).children.compactMap { label, value in
            guard let label, let hex = value as? String else { return nil }
            return parseHexColor(hex) == nil ? label : nil
        }
    }
}

private extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
