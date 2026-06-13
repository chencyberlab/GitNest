import Foundation

/// Every selectable colour scheme. The built-in GitNest palette preserves the
/// app's original look; the rest come from `planned_colour_schemes.md`.
let allPalettes: [ColorThemePalette] = [
    .gitNest,
    .catppuccin,
    .dracula,
    .nord,
    .tokyoNight,
    .solarized,
    .gruvbox,
    .rosePine,
    .flexoki,
    .ayu
]

extension ColorThemePalette {
    static let gitNest = ColorThemePalette(
        id: "gitnest",
        displayName: "GitNest",
        light: .gitNestLight,
        dark: .gitNestDark
    )

    static let catppuccin = ColorThemePalette(
        id: "catppuccin",
        displayName: "Catppuccin",
        light: .catppuccinLatte,
        dark: .catppuccinMocha
    )

    static let dracula = ColorThemePalette(
        id: "dracula",
        displayName: "Dracula",
        light: .draculaLight,
        dark: .draculaDark
    )

    static let nord = ColorThemePalette(
        id: "nord",
        displayName: "Nord",
        light: .nordLight,
        dark: .nordDark
    )

    static let tokyoNight = ColorThemePalette(
        id: "tokyo-night",
        displayName: "Tokyo Night",
        light: .tokyoNightDay,
        dark: .tokyoNightNight
    )

    static let solarized = ColorThemePalette(
        id: "solarized",
        displayName: "Solarized",
        light: .solarizedLight,
        dark: .solarizedDark
    )

    static let gruvbox = ColorThemePalette(
        id: "gruvbox",
        displayName: "Gruvbox",
        light: .gruvboxLight,
        dark: .gruvboxDark
    )

    static let rosePine = ColorThemePalette(
        id: "rose-pine",
        displayName: "Rosé Pine",
        light: .rosePineDawn,
        dark: .rosePineMain
    )

    static let flexoki = ColorThemePalette(
        id: "flexoki",
        displayName: "Flexoki",
        light: .flexokiLight,
        dark: .flexokiDark
    )

    static let ayu = ColorThemePalette(
        id: "ayu",
        displayName: "Ayu",
        light: .ayuLight,
        dark: .ayuDark
    )

}

// MARK: - GitNest (original app palette)

private extension ColorThemeTokens {
    static let gitNestLight = ColorThemeTokens(
        background: nil,
        surface: nil,
        elevatedSurface: nil,
        surfaceMuted: "#F5F3F7",
        text: nil,
        textMuted: "#5E5968",
        textTertiary: "#777381",
        border: "#D7D3DDBF",
        primary: "#7132F5",
        primaryText: "#F4F1FF",
        primarySubtle: alphaHex("#855BFB", 0.18),
        accent: "#7132F5",
        accentSubtle: alphaHex("#855BFB", 0.18),
        success: "#149E61",
        successSubtle: alphaHex("#149E61", 0.18),
        warning: "#B7791F",
        warningSubtle: alphaHex("#D69E2E", 0.18),
        error: "#D72D35",
        errorSubtle: alphaHex("#E5484D", 0.16),
        tooltipBackground: "#FFFFFF",
        tooltipText: "#2F2A38",
        blue: "#2563EB",
        teal: "#0F8A8A",
        pink: "#C2185B"
    )

    static let gitNestDark = ColorThemeTokens(
        background: nil,
        surface: nil,
        elevatedSurface: nil,
        surfaceMuted: "#28262C",
        text: nil,
        textMuted: "#CAC6D4",
        textTertiary: "#A29DAD",
        border: "#56515FD9",
        primary: "#A78BFA",
        primaryText: "#302A3C",
        primarySubtle: alphaHex("#A78BFA", 0.24),
        accent: "#A78BFA",
        accentSubtle: alphaHex("#A78BFA", 0.24),
        success: "#4ADE9A",
        successSubtle: alphaHex("#4ADE9A", 0.18),
        warning: "#F6C453",
        warningSubtle: alphaHex("#F6C453", 0.20),
        error: "#FF6B73",
        errorSubtle: alphaHex("#FF6B73", 0.22),
        tooltipBackground: "#1F1D24",
        tooltipText: "#F2F0F8",
        blue: "#7AA2F7",
        teal: "#4FD6C9",
        pink: "#F472B6"
    )
}

// MARK: - Planned schemes

private extension ColorThemeTokens {
    static let catppuccinLatte = fromPlanned(
        background: "#EFF1F5",
        surface: "#E6E9EF",
        elevatedSurface: "#DCE0E8",
        text: "#4C4F69",
        textMuted: "#6C6F85",
        border: "#BCC0CC",
        primary: "#1E66F5",
        primaryText: "#FFFFFF",
        accent: "#8839EF",
        success: "#40A02B",
        warning: "#DF8E1D",
        error: "#D20F39",
        selection: "#CCD0DA",
        tooltipBackground: "#DCE0E8",
        tooltipText: "#4C4F69",
        blue: "#1E66F5",
        teal: "#179299",
        pink: "#EA76CB"
    )

    static let catppuccinMocha = fromPlanned(
        background: "#1E1E2E",
        surface: "#181825",
        elevatedSurface: "#313244",
        text: "#CDD6F4",
        textMuted: "#A6ADC8",
        border: "#45475A",
        primary: "#89B4FA",
        primaryText: "#1E1E2E",
        accent: "#CBA6F7",
        success: "#A6E3A1",
        warning: "#F9E2AF",
        error: "#F38BA8",
        selection: "#585B70",
        tooltipBackground: "#313244",
        tooltipText: "#CDD6F4",
        blue: "#89B4FA",
        teal: "#94E2D5",
        pink: "#F5C2E7"
    )

    /// Official Dracula is a dark theme. The light variant uses Dracula's own
    /// palette, but the pure Dracula accent colors are too bright on a light
    /// background, so they are darkened for comfortable contrast.
    static let draculaLight = ColorThemeTokens(
        background: "#F8F8F2",
        surface: "#EAEAE2",
        elevatedSurface: "#FFFFFF",
        surfaceMuted: "#EAEAE2",
        text: "#282A36",
        textMuted: "#6272A4",
        textTertiary: "#6272A4",
        border: "#CFCFDE",
        primary: "#7B61A8",
        primaryText: "#FFFFFF",
        primarySubtle: alphaHex("#7B61A8", 0.18),
        accent: "#C94D92",
        accentSubtle: alphaHex("#C94D92", 0.18),
        success: "#2FA65A",
        successSubtle: alphaHex("#2FA65A", 0.18),
        warning: "#B5A832",
        warningSubtle: alphaHex("#B5A832", 0.25),
        error: "#D93A3A",
        errorSubtle: alphaHex("#D93A3A", 0.18),
        tooltipBackground: "#FFFFFF",
        tooltipText: "#282A36",
        blue: "#3D8FB0",
        teal: "#3D8FB0",
        pink: "#C94D92"
    )

    static let draculaDark = ColorThemeTokens(
        background: "#282A36",
        surface: "#21222C",
        elevatedSurface: "#44475A",
        surfaceMuted: "#44475A",
        text: "#F8F8F2",
        textMuted: "#6272A4",
        textTertiary: "#6272A4",
        border: "#44475A",
        primary: "#BD93F9",
        primaryText: "#282A36",
        primarySubtle: alphaHex("#BD93F9", 0.24),
        accent: "#FF79C6",
        accentSubtle: alphaHex("#FF79C6", 0.24),
        success: "#50FA7B",
        successSubtle: alphaHex("#50FA7B", 0.18),
        warning: "#F1FA8C",
        warningSubtle: alphaHex("#F1FA8C", 0.18),
        error: "#FF5555",
        errorSubtle: alphaHex("#FF5555", 0.18),
        tooltipBackground: "#44475A",
        tooltipText: "#F8F8F2",
        blue: "#8BE9FD",
        teal: "#8BE9FD",
        pink: "#FF79C6"
    )

    static let nordLight = fromPlanned(
        background: "#ECEFF4",
        surface: "#E5E9F0",
        elevatedSurface: "#D8DEE9",
        text: "#2E3440",
        textMuted: "#4C566A",
        border: "#D8DEE9",
        primary: "#5E81AC",
        primaryText: "#FFFFFF",
        accent: "#B48EAD",
        success: "#A3BE8C",
        warning: "#EBCB8B",
        error: "#BF616A",
        selection: "#D8DEE9",
        tooltipBackground: "#D8DEE9",
        tooltipText: "#2E3440",
        blue: "#5E81AC",
        teal: "#8FBCBB",
        pink: "#B48EAD"
    )

    static let nordDark = fromPlanned(
        background: "#2E3440",
        surface: "#3B4252",
        elevatedSurface: "#434C5E",
        text: "#ECEFF4",
        textMuted: "#D8DEE9",
        border: "#4C566A",
        primary: "#88C0D0",
        primaryText: "#2E3440",
        accent: "#B48EAD",
        success: "#A3BE8C",
        warning: "#EBCB8B",
        error: "#BF616A",
        selection: "#4C566A",
        tooltipBackground: "#434C5E",
        tooltipText: "#ECEFF4",
        blue: "#88C0D0",
        teal: "#8FBCBB",
        pink: "#B48EAD"
    )

    /// Tokyo Night's official "Day" palette is an editor theme: its background is
    /// cool and dim, and its foreground is a bright, saturated blue. For a macOS
    /// app UI that reads as a true light mode, we keep the Tokyo Night identity
    /// (blue primary, purple accent, cool cast) but lift the background to a clean
    /// near-white, swap the bright-blue body text for a dark blue-grey, and tighten
    /// surface contrast and semantic colours.
    static let tokyoNightDay = fromPlanned(
        background: "#F5F6FA",
        surface: "#EBEEF5",
        elevatedSurface: "#FFFFFF",
        text: "#252B47",
        textMuted: "#5A648C",
        border: "#D8DCE8",
        primary: "#2E7DE9",
        primaryText: "#FFFFFF",
        accent: "#9854F1",
        success: "#3A7A2C",
        warning: "#9F7428",
        error: "#D93A5E",
        selection: "#D4DBF0",
        tooltipBackground: "#FFFFFF",
        tooltipText: "#252B47",
        blue: "#2E7DE9",
        teal: "#0D8A72",
        pink: "#9854F1"
    )

    static let tokyoNightNight = fromPlanned(
        background: "#1A1B26",
        surface: "#16161E",
        elevatedSurface: "#292E42",
        text: "#C0CAF5",
        textMuted: "#565F89",
        border: "#414868",
        primary: "#7AA2F7",
        primaryText: "#1A1B26",
        accent: "#BB9AF7",
        success: "#9ECE6A",
        warning: "#E0AF68",
        error: "#F7768E",
        selection: "#283457",
        tooltipBackground: "#292E42",
        tooltipText: "#C0CAF5",
        blue: "#7AA2F7",
        teal: "#1ABC9C",
        pink: "#BB9AF7"
    )

    static let solarizedLight = fromPlanned(
        background: "#FDF6E3",
        surface: "#EEE8D5",
        elevatedSurface: "#FFFFFF",
        text: "#657B83",
        textMuted: "#93A1A1",
        border: "#EEE8D5",
        primary: "#268BD2",
        primaryText: "#FFFFFF",
        accent: "#6C71C4",
        success: "#859900",
        warning: "#B58900",
        error: "#DC322F",
        selection: "#EEE8D5",
        tooltipBackground: "#FFFFFF",
        tooltipText: "#657B83",
        blue: "#268BD2",
        teal: "#2AA198",
        pink: "#D33682"
    )

    static let solarizedDark = fromPlanned(
        background: "#002B36",
        surface: "#073642",
        elevatedSurface: "#0B3A46",
        text: "#839496",
        textMuted: "#586E75",
        border: "#073642",
        primary: "#268BD2",
        primaryText: "#002B36",
        accent: "#6C71C4",
        success: "#859900",
        warning: "#B58900",
        error: "#DC322F",
        selection: "#073642",
        tooltipBackground: "#0B3A46",
        tooltipText: "#839496",
        blue: "#268BD2",
        teal: "#2AA198",
        pink: "#D33682"
    )

    static let gruvboxLight = fromPlanned(
        background: "#FBF1C7",
        surface: "#EBDBB2",
        elevatedSurface: "#D5C4A1",
        text: "#3C3836",
        textMuted: "#7C6F64",
        border: "#D5C4A1",
        primary: "#458588",
        primaryText: "#FFFFFF",
        accent: "#B16286",
        success: "#98971A",
        warning: "#D79921",
        error: "#CC241D",
        selection: "#D5C4A1",
        tooltipBackground: "#D5C4A1",
        tooltipText: "#3C3836",
        blue: "#458588",
        teal: "#689D6A",
        pink: "#B16286"
    )

    static let gruvboxDark = fromPlanned(
        background: "#282828",
        surface: "#3C3836",
        elevatedSurface: "#504945",
        text: "#EBDBB2",
        textMuted: "#A89984",
        border: "#504945",
        primary: "#83A598",
        primaryText: "#282828",
        accent: "#D3869B",
        success: "#B8BB26",
        warning: "#FABD2F",
        error: "#FB4934",
        selection: "#504945",
        tooltipBackground: "#504945",
        tooltipText: "#EBDBB2",
        blue: "#83A598",
        teal: "#8EC07C",
        pink: "#D3869B"
    )

    static let rosePineDawn = fromPlanned(
        background: "#FAF4ED",
        surface: "#FFFAF3",
        elevatedSurface: "#F2E9E1",
        text: "#575279",
        textMuted: "#797593",
        border: "#DFDAD9",
        primary: "#286983",
        primaryText: "#FFFFFF",
        accent: "#907AA9",
        success: "#56949F",
        warning: "#EA9D34",
        error: "#B4637A",
        selection: "#DFDAD9",
        tooltipBackground: "#F2E9E1",
        tooltipText: "#575279",
        blue: "#286983",
        teal: "#56949F",
        pink: "#907AA9"
    )

    static let rosePineMain = fromPlanned(
        background: "#191724",
        surface: "#1F1D2E",
        elevatedSurface: "#26233A",
        text: "#E0DEF4",
        textMuted: "#908CAA",
        border: "#403D52",
        primary: "#31748F",
        primaryText: "#E0DEF4",
        accent: "#C4A7E7",
        success: "#9CCFD8",
        warning: "#F6C177",
        error: "#EB6F92",
        selection: "#403D52",
        tooltipBackground: "#26233A",
        tooltipText: "#E0DEF4",
        blue: "#31748F",
        teal: "#9CCFD8",
        pink: "#C4A7E7"
    )

    static let flexokiLight = fromPlanned(
        background: "#FFFCF0",
        surface: "#F2F0E5",
        elevatedSurface: "#E6E4D9",
        text: "#100F0F",
        textMuted: "#6F6E69",
        border: "#CECDC3",
        primary: "#205EA6",
        primaryText: "#FFFFFF",
        accent: "#5E409D",
        success: "#66800B",
        warning: "#AD8301",
        error: "#AF3029",
        selection: "#E6E4D9",
        tooltipBackground: "#E6E4D9",
        tooltipText: "#100F0F",
        blue: "#205EA6",
        teal: "#24837B",
        pink: "#A02F6F"
    )

    static let flexokiDark = fromPlanned(
        background: "#100F0F",
        surface: "#1C1B1A",
        elevatedSurface: "#282726",
        text: "#FFFCF0",
        textMuted: "#B7B5AC",
        border: "#343331",
        primary: "#4385BE",
        primaryText: "#100F0F",
        accent: "#8B7EC8",
        success: "#879A39",
        warning: "#D0A215",
        error: "#D14D41",
        selection: "#343331",
        tooltipBackground: "#282726",
        tooltipText: "#FFFCF0",
        blue: "#4385BE",
        teal: "#3AA99F",
        pink: "#CE5D97"
    )

    static let ayuLight = fromPlanned(
        background: "#FAFAFA",
        surface: "#F3F4F5",
        elevatedSurface: "#FFFFFF",
        text: "#5C6773",
        textMuted: "#ABB0B6",
        border: "#D9D8D7",
        primary: "#399EE6",
        primaryText: "#0A0E14",
        accent: "#A37ACC",
        success: "#86B300",
        warning: "#F2AE49",
        error: "#F51818",
        selection: "#E6E6E6",
        tooltipBackground: "#FFFFFF",
        tooltipText: "#5C6773",
        blue: "#399EE6",
        teal: "#4CBF99",
        pink: "#A37ACC"
    )

    static let ayuDark = fromPlanned(
        background: "#0A0E14",
        surface: "#0D1017",
        elevatedSurface: "#1C212A",
        text: "#B3B1AD",
        textMuted: "#626A73",
        border: "#1C212A",
        primary: "#59C2FF",
        primaryText: "#0A0E14",
        accent: "#D2A6FF",
        success: "#AAD94C",
        warning: "#E6B450",
        error: "#FF3333",
        selection: "#1C212A",
        tooltipBackground: "#1C212A",
        tooltipText: "#B3B1AD",
        blue: "#59C2FF",
        teal: "#95E6CB",
        pink: "#D2A6FF"
    )

}

// MARK: - Helpers

private extension ColorThemeTokens {
    static func fromPlanned(
        background: String,
        surface: String,
        elevatedSurface: String,
        text: String,
        textMuted: String,
        border: String,
        primary: String,
        primaryText: String,
        accent: String,
        success: String,
        warning: String,
        error: String,
        selection: String,
        tooltipBackground: String,
        tooltipText: String,
        blue: String,
        teal: String,
        pink: String
    ) -> ColorThemeTokens {
        ColorThemeTokens(
            background: background,
            surface: surface,
            elevatedSurface: elevatedSurface,
            surfaceMuted: surface,
            text: text,
            textMuted: textMuted,
            textTertiary: textMuted,
            border: border,
            primary: primary,
            primaryText: primaryText,
            primarySubtle: selection,
            accent: accent,
            accentSubtle: selection,
            success: success,
            successSubtle: alphaHex(success, 0.18),
            warning: warning,
            warningSubtle: alphaHex(warning, 0.18),
            error: error,
            errorSubtle: alphaHex(error, 0.18),
            tooltipBackground: tooltipBackground,
            tooltipText: tooltipText,
            blue: blue,
            teal: teal,
            pink: pink
        )
    }
}

private func alphaHex(_ hex: String, _ alpha: Double) -> String {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    let a = max(0, min(255, Int(round(alpha * 255))))
    return "#" + cleaned + String(format: "%02X", a)
}
