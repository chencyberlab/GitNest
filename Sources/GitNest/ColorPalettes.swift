import Foundation

/// Every selectable colour scheme. The built-in GitNest palette preserves the
/// app's original look; the rest come from `planned_colour_schemes.md`.
let allPalettes: [ColorThemePalette] = [
    .gitNest,
    .github,
    .catppuccin,
    .dracula,
    .nord,
    .tokyoNight,
    .solarized,
    .gruvbox,
    .rosePine,
    .flexoki,
    .ayu,
    .oneAtom,
    .everforest,
    .material,
    .cyberpunk
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

    static let github = ColorThemePalette(
        id: "github",
        displayName: "GitHub",
        light: .githubLight,
        dark: .githubDark
    )

    static let oneAtom = ColorThemePalette(
        id: "one",
        displayName: "One",
        light: .oneLight,
        dark: .oneDark
    )

    static let everforest = ColorThemePalette(
        id: "everforest",
        displayName: "Everforest",
        light: .everforestLight,
        dark: .everforestDark
    )

    static let material = ColorThemePalette(
        id: "material",
        displayName: "Material",
        light: .materialLight,
        dark: .materialDark
    )

    static let cyberpunk = ColorThemePalette(
        id: "cyberpunk",
        displayName: "Cyberpunk",
        light: .cyberpunkLight,
        dark: .cyberpunkNight
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
        // Derived one step from `surface` toward `text` (matches the fromPlanned
        // formula) — the old `#EAEAE2` aliased `surface` and made hover/search/log
        // fills invisible, the same collision third-party themes had.
        surfaceMuted: mixHex("#EAEAE2", "#282A36", 0.08),
        text: "#282A36",
        textMuted: "#6272A4",
        textTertiary: mixHex("#6272A4", "#F8F8F2", 0.2),
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
        tooltipBackground: "#F5F5F3",
        tooltipText: "#282A36",
        blue: "#3D8FB0",
        teal: "#3D8FB0",
        pink: "#C94D92"
    )

    static let draculaDark = ColorThemeTokens(
        background: "#282A36",
        surface: "#21222C",
        elevatedSurface: "#44475A",
        // Derived one step from `surface` toward `text` (matches the fromPlanned
        // formula). The old value aliased `elevatedSurface` (#44475A), skipping a
        // tier in the hierarchy; this keeps surfaceMuted as a quiet wash between
        // surface and elevatedSurface.
        surfaceMuted: mixHex("#21222C", "#F8F8F2", 0.08),
        text: "#F8F8F2",
        textMuted: "#6272A4",
        textTertiary: mixHex("#6272A4", "#282A36", 0.2),
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
        tooltipBackground: "#4A4D60",
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
        tooltipText: "#B3B1AD",
        blue: "#59C2FF",
        teal: "#95E6CB",
        pink: "#D2A6FF"
    )

    // GitHub's own Primer palette — a fitting default for a GitHub tool. Blue is
    // the primary (links/buttons), purple the accent, with Primer's semantic reds,
    // greens, and ambers. The selection tone is a neutral canvas inset.
    static let githubLight = fromPlanned(
        background: "#FFFFFF",
        surface: "#F6F8FA",
        elevatedSurface: "#FFFFFF",
        text: "#1F2328",
        textMuted: "#656D76",
        border: "#D0D7DE",
        primary: "#0969DA",
        primaryText: "#FFFFFF",
        accent: "#8250DF",
        success: "#1A7F37",
        warning: "#9A6700",
        error: "#CF222E",
        tooltipText: "#1F2328",
        blue: "#0969DA",
        teal: "#1B7C83",
        pink: "#BF3989"
    )

    static let githubDark = fromPlanned(
        background: "#0D1117",
        surface: "#161B22",
        elevatedSurface: "#21262D",
        text: "#E6EDF3",
        textMuted: "#8B949E",
        border: "#30363D",
        primary: "#1F6FEB",
        primaryText: "#FFFFFF",
        accent: "#A371F7",
        success: "#3FB950",
        warning: "#D29922",
        error: "#F85149",
        tooltipText: "#E6EDF3",
        blue: "#2F81F7",
        teal: "#56D4DD",
        pink: "#DB61A2"
    )

    // Atom's One Light / One Dark — one of the most widely used editor themes.
    // Blue primary, magenta accent, with One's signature green/gold/red.
    static let oneLight = fromPlanned(
        background: "#FAFAFA",
        surface: "#EAEAEB",
        elevatedSurface: "#FFFFFF",
        text: "#383A42",
        textMuted: "#696C77",
        border: "#D4D4D6",
        primary: "#4078F2",
        primaryText: "#FFFFFF",
        accent: "#A626A4",
        success: "#50A14F",
        warning: "#C18401",
        error: "#E45649",
        tooltipText: "#383A42",
        blue: "#4078F2",
        teal: "#0184BC",
        pink: "#A626A4"
    )

    static let oneDark = fromPlanned(
        background: "#282C34",
        surface: "#21252B",
        elevatedSurface: "#2C313A",
        text: "#ABB2BF",
        textMuted: "#828997",
        border: "#3B4048",
        primary: "#61AFEF",
        primaryText: "#282C34",
        accent: "#C678DD",
        success: "#98C379",
        warning: "#E5C07B",
        error: "#E06C75",
        tooltipText: "#ABB2BF",
        blue: "#61AFEF",
        teal: "#56B6C2",
        pink: "#C678DD"
    )

    // Everforest — a warm, low-contrast green-based scheme that's easy on the eyes.
    // Aqua/blue primary, a soft magenta accent, and its muted earthy semantics.
    static let everforestLight = fromPlanned(
        background: "#FDF6E3",
        surface: "#F4F0D9",
        elevatedSurface: "#FFFBEF",
        text: "#5C6A72",
        textMuted: "#939F91",
        border: "#DDD8BE",
        primary: "#3A94C5",
        primaryText: "#FFFFFF",
        accent: "#DF69BA",
        success: "#8DA101",
        warning: "#DFA000",
        error: "#F85552",
        tooltipText: "#5C6A72",
        blue: "#3A94C5",
        teal: "#35A77C",
        pink: "#DF69BA"
    )

    static let everforestDark = fromPlanned(
        background: "#2D353B",
        surface: "#272E33",
        elevatedSurface: "#343F44",
        text: "#D3C6AA",
        textMuted: "#9DA9A0",
        border: "#404B51",
        primary: "#7FBBB3",
        primaryText: "#2D353B",
        accent: "#D699B6",
        success: "#A7C080",
        warning: "#DBBC7F",
        error: "#E67E80",
        tooltipText: "#D3C6AA",
        blue: "#7FBBB3",
        teal: "#83C092",
        pink: "#D699B6"
    )

    // Material Theme — the popular Material Design editor palette. A clean light
    // variant and the classic dark "Oceanic" tones: blue primary, purple accent.
    static let materialLight = fromPlanned(
        background: "#FAFAFA",
        surface: "#F4F4F4",
        elevatedSurface: "#FFFFFF",
        text: "#37474F",
        textMuted: "#7E939E",
        border: "#D3DEE3",
        primary: "#6182B8",
        primaryText: "#FFFFFF",
        accent: "#7C4DFF",
        success: "#91B859",
        warning: "#F6A434",
        error: "#E53935",
        tooltipText: "#37474F",
        blue: "#6182B8",
        teal: "#39ADB5",
        pink: "#FF5370"
    )

    static let materialDark = fromPlanned(
        background: "#263238",
        surface: "#20292E",
        elevatedSurface: "#2E3C43",
        text: "#CFD8DC",
        textMuted: "#7E97A3",
        border: "#37474F",
        primary: "#82AAFF",
        primaryText: "#263238",
        accent: "#C792EA",
        success: "#C3E88D",
        warning: "#FFCB6B",
        error: "#FF5370",
        tooltipText: "#CFD8DC",
        blue: "#82AAFF",
        teal: "#89DDFF",
        pink: "#F07178"
    )

    // Cyberpunk / synthwave — neon-on-dark is the hero. Electric cyan primary, hot
    // magenta accent, acid-yellow warning, all glowing on a deep purple-navy. The
    // light variant keeps the cyan/magenta identity but darkens the neons for
    // contrast on a pale lavender canvas (the same trade-off as Dracula Light).
    static let cyberpunkNight = fromPlanned(
        background: "#0D0B1F",
        surface: "#141229",
        elevatedSurface: "#1E1B3A",
        text: "#E6F2FF",
        textMuted: "#8B9BC4",
        border: "#332F5E",
        primary: "#18E0F5",
        primaryText: "#0D0B1F",
        accent: "#FF49C0",
        success: "#1FE6A8",
        warning: "#F5D90A",
        error: "#FF3366",
        tooltipText: "#E6F2FF",
        blue: "#4D8DFF",
        teal: "#1DE9B6",
        pink: "#FF6AC1"
    )

    static let cyberpunkLight = fromPlanned(
        background: "#F6F4FE",
        surface: "#ECE9F7",
        elevatedSurface: "#FFFFFF",
        text: "#1A1730",
        textMuted: "#5C5680",
        border: "#DAD4EE",
        primary: "#0C7D99",
        primaryText: "#FFFFFF",
        accent: "#C81E8E",
        success: "#0A8F60",
        warning: "#A8780A",
        error: "#E0244E",
        tooltipText: "#1A1730",
        blue: "#2D5BD8",
        teal: "#0A9488",
        pink: "#C81E8E"
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
        tooltipText: String,
        blue: String,
        teal: String,
        pink: String
    ) -> ColorThemeTokens {
        ColorThemeTokens(
            background: background,
            surface: surface,
            elevatedSurface: elevatedSurface,
            // A genuine surface tier one step from `surface` toward `text`. Without
            // this, `surfaceMuted` used to alias `surface`, which made every fill
            // meant to read as "subtly different from the background" — row hover,
            // search fields, the Output panel — invisible. The blend direction toward
            // `text` guarantees a visible step on both light and dark palettes, and
            // mirrors the hand-tuned hierarchy the built-in GitNest theme has. Kept
            // gentle (0.08) so it stays a quiet wash rather than a competing fill;
            // Solarized dark's deliberately low-contrast mid-tone surface/text pair
            // is the floor case, and 0.08 keeps even that above a perceptible step.
            surfaceMuted: mixHex(surface, text, 0.08),
            text: text,
            textMuted: textMuted,
            // A genuine third text tier: a quieter tone eased toward the background,
            // so subtle labels ("+N more", counts, the version string, settings help)
            // sit a step below muted instead of matching it. Mirrors the hand-tuned
            // hierarchy the built-in GitNest theme already has. The blend is kept
            // gentle (0.2) so themes whose muted is already soft (Ayu, Solarized)
            // don't push their faintest text past legibility.
            textTertiary: mixHex(textMuted, background, 0.2),
            border: border,
            primary: primary,
            primaryText: primaryText,
            primarySubtle: alphaHex(primary, 0.18),
            accent: accent,
            accentSubtle: alphaHex(accent, 0.18),
            success: success,
            successSubtle: alphaHex(success, 0.18),
            warning: warning,
            warningSubtle: alphaHex(warning, 0.18),
            error: error,
            errorSubtle: alphaHex(error, 0.18),
            // A distinct floating surface for tooltips: a tiny step from
            // `elevatedSurface` toward `text` so the bubble is perceptibly
            // different from raised cards (which use `elevatedSurface`) while
            // staying in the same surface family. The 0.06 blend is gentle
            // enough that it doesn't fight the tooltip's shadow + border.
            tooltipBackground: mixHex(elevatedSurface, text, 0.06),
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

/// Linearly blend two opaque hex colours by `t` in [0, 1] (`t = 0` → `a`, `t = 1`
/// → `b`), returning an opaque `#RRGGBB`. Accepts `#RGB`, `#RRGGBB`, or
/// `#RRGGBBAA` (alpha is dropped). Used to derive a third-tier text colour by
/// easing a muted tone toward the background.
private func mixHex(_ a: String, _ b: String, _ t: Double) -> String {
    func rgb(_ hex: String) -> (Double, Double, Double) {
        let c = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: c).scanHexInt64(&v)
        switch c.count {
        case 3:
            return (Double((v >> 8) & 0xF) * 17, Double((v >> 4) & 0xF) * 17, Double(v & 0xF) * 17)
        case 8:   // #RRGGBBAA — drop the trailing alpha byte
            return (Double((v >> 24) & 0xFF), Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF))
        default:  // #RRGGBB
            return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
        }
    }
    let f = max(0, min(1, t))
    let (ar, ag, ab) = rgb(a)
    let (br, bg, bb) = rgb(b)
    let r = Int(round(ar + (br - ar) * f))
    let g = Int(round(ag + (bg - ag) * f))
    let bl = Int(round(ab + (bb - ab) * f))
    return String(format: "#%02X%02X%02X", r, g, bl)
}
