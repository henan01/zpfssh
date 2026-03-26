import AppKit

struct TerminalTheme: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var background: CodableColor
    var foreground: CodableColor
    var cursor: CodableColor
    var selectionBackground: CodableColor
    var ansiColors: [CodableColor]  // 16 ANSI colors

    func toColorProvider() -> ThemeColorProvider {
        ThemeColorProvider(theme: self)
    }
}

struct CodableColor: Codable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1.0

    var nsColor: NSColor {
        NSColor(red: r, green: g, blue: b, alpha: a)
    }

    init(_ color: NSColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.r = Double(r)
        self.g = Double(g)
        self.b = Double(b)
        self.a = Double(a)
    }

    init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    static func hex(_ hex: String) -> CodableColor {
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 6 { h += "ff" }
        let v = UInt64(h, radix: 16) ?? 0
        return CodableColor(
            r: Double((v >> 24) & 0xFF) / 255,
            g: Double((v >> 16) & 0xFF) / 255,
            b: Double((v >> 8)  & 0xFF) / 255,
            a: Double(v & 0xFF) / 255
        )
    }
}

class ThemeColorProvider {
    let theme: TerminalTheme
    init(theme: TerminalTheme) { self.theme = theme }
}

enum BackgroundType: String, Codable, CaseIterable {
    case solidColor  = "纯色"
    case image       = "图片"
    case gradient    = "渐变"
}

struct AppearanceSettings: Codable {
    var themeId: String = "zen-dark"
    var fontName: String = "Menlo"
    var fontSize: Double = 13
    var backgroundType: BackgroundType = .solidColor
    var backgroundImagePath: String = ""
    var backgroundOpacity: Double = 0.3
    var backgroundBlur: Double = 0
    var imageFillMode: ImageFillMode = .aspectFill
    var gradientStart: CodableColor = CodableColor.hex("#1a1b26ff")
    var gradientEnd: CodableColor = CodableColor.hex("#24283bff")
    var cursorBlink: Bool = true
    var windowOpacity: Double = 1.0
}

enum ImageFillMode: String, Codable, CaseIterable {
    case stretch     = "拉伸"
    case aspectFit   = "等比适应"
    case aspectFill  = "等比填充"
    case tile        = "平铺"
    case center      = "居中"
}

extension TerminalTheme {
    static let builtins: [TerminalTheme] = [zenDark, zenLight, oneDark, dracula, nord, tokyoNight, solarizedDark, monokai, gruvbox, solarizedLight]

    static let zenDark = TerminalTheme(
        id: "zen-dark", name: "Zen Dark",
        background: .hex("#1c1e26ff"), foreground: .hex("#e0e0e0ff"),
        cursor: .hex("#c792eaff"), selectionBackground: .hex("#3d4166ff"),
        ansiColors: zenDarkAnsi
    )
    static let zenLight = TerminalTheme(
        id: "zen-light", name: "Zen Light",
        background: .hex("#fafafaff"), foreground: .hex("#383a42ff"),
        cursor: .hex("#526fffff"), selectionBackground: .hex("#d3d3e6ff"),
        ansiColors: zenLightAnsi
    )
    static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark Pro",
        background: .hex("#282c34ff"), foreground: .hex("#abb2bfff"),
        cursor: .hex("#528bffff"), selectionBackground: .hex("#3e4451ff"),
        ansiColors: oneDarkAnsi
    )
    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula",
        background: .hex("#282a36ff"), foreground: .hex("#f8f8f2ff"),
        cursor: .hex("#bd93f9ff"), selectionBackground: .hex("#44475aff"),
        ansiColors: draculaAnsi
    )
    static let nord = TerminalTheme(
        id: "nord", name: "Nord",
        background: .hex("#2e3440ff"), foreground: .hex("#d8dee9ff"),
        cursor: .hex("#88c0d0ff"), selectionBackground: .hex("#434c5eff"),
        ansiColors: nordAnsi
    )
    static let tokyoNight = TerminalTheme(
        id: "tokyo-night", name: "Tokyo Night",
        background: .hex("#1a1b26ff"), foreground: .hex("#c0caf5ff"),
        cursor: .hex("#bb9af7ff"), selectionBackground: .hex("#283457ff"),
        ansiColors: tokyoNightAnsi
    )
    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark",
        background: .hex("#002b36ff"), foreground: .hex("#839496ff"),
        cursor: .hex("#268bd2ff"), selectionBackground: .hex("#073642ff"),
        ansiColors: solarizedDarkAnsi
    )
    static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light",
        background: .hex("#fdf6e3ff"), foreground: .hex("#657b83ff"),
        cursor: .hex("#268bd2ff"), selectionBackground: .hex("#eee8d5ff"),
        ansiColors: solarizedLightAnsi
    )
    static let monokai = TerminalTheme(
        id: "monokai", name: "Monokai",
        background: .hex("#272822ff"), foreground: .hex("#f8f8f2ff"),
        cursor: .hex("#f8f8f0ff"), selectionBackground: .hex("#49483eff"),
        ansiColors: monokaiAnsi
    )
    static let gruvbox = TerminalTheme(
        id: "gruvbox", name: "Gruvbox",
        background: .hex("#282828ff"), foreground: .hex("#ebdbb2ff"),
        cursor: .hex("#fe8019ff"), selectionBackground: .hex("#3c3836ff"),
        ansiColors: gruvboxAnsi
    )

    // ANSI 16-color palettes
    static let zenDarkAnsi: [CodableColor] = [
        .hex("#1c1e26"), .hex("#e95678"), .hex("#29d398"), .hex("#fab795"),
        .hex("#26bbd9"), .hex("#ee64ac"), .hex("#59e3e3"), .hex("#d5d8da"),
        .hex("#6f6f6f"), .hex("#ec6a88"), .hex("#3fdaa4"), .hex("#fbc3a7"),
        .hex("#3fc4de"), .hex("#f075b7"), .hex("#6be6e6"), .hex("#ffffff")
    ]
    static let zenLightAnsi: [CodableColor] = [
        .hex("#383a42"), .hex("#e45649"), .hex("#50a14f"), .hex("#c18401"),
        .hex("#0184bc"), .hex("#a626a4"), .hex("#0997b3"), .hex("#fafafa"),
        .hex("#4f525e"), .hex("#e45649"), .hex("#50a14f"), .hex("#c18401"),
        .hex("#0184bc"), .hex("#a626a4"), .hex("#0997b3"), .hex("#ffffff")
    ]
    static let oneDarkAnsi: [CodableColor] = [
        .hex("#282c34"), .hex("#e06c75"), .hex("#98c379"), .hex("#e5c07b"),
        .hex("#61afef"), .hex("#c678dd"), .hex("#56b6c2"), .hex("#abb2bf"),
        .hex("#5c6370"), .hex("#e06c75"), .hex("#98c379"), .hex("#e5c07b"),
        .hex("#61afef"), .hex("#c678dd"), .hex("#56b6c2"), .hex("#ffffff")
    ]
    static let draculaAnsi: [CodableColor] = [
        .hex("#21222c"), .hex("#ff5555"), .hex("#50fa7b"), .hex("#f1fa8c"),
        .hex("#bd93f9"), .hex("#ff79c6"), .hex("#8be9fd"), .hex("#f8f8f2"),
        .hex("#6272a4"), .hex("#ff6e6e"), .hex("#69ff94"), .hex("#ffffa5"),
        .hex("#d6acff"), .hex("#ff92df"), .hex("#a4ffff"), .hex("#ffffff")
    ]
    static let nordAnsi: [CodableColor] = [
        .hex("#3b4252"), .hex("#bf616a"), .hex("#a3be8c"), .hex("#ebcb8b"),
        .hex("#81a1c1"), .hex("#b48ead"), .hex("#88c0d0"), .hex("#e5e9f0"),
        .hex("#4c566a"), .hex("#bf616a"), .hex("#a3be8c"), .hex("#ebcb8b"),
        .hex("#81a1c1"), .hex("#b48ead"), .hex("#8fbcbb"), .hex("#eceff4")
    ]
    static let tokyoNightAnsi: [CodableColor] = [
        .hex("#15161e"), .hex("#f7768e"), .hex("#9ece6a"), .hex("#e0af68"),
        .hex("#7aa2f7"), .hex("#bb9af7"), .hex("#7dcfff"), .hex("#a9b1d6"),
        .hex("#414868"), .hex("#f7768e"), .hex("#9ece6a"), .hex("#e0af68"),
        .hex("#7aa2f7"), .hex("#bb9af7"), .hex("#7dcfff"), .hex("#c0caf5")
    ]
    static let solarizedDarkAnsi: [CodableColor] = [
        .hex("#073642"), .hex("#dc322f"), .hex("#859900"), .hex("#b58900"),
        .hex("#268bd2"), .hex("#d33682"), .hex("#2aa198"), .hex("#eee8d5"),
        .hex("#002b36"), .hex("#cb4b16"), .hex("#586e75"), .hex("#657b83"),
        .hex("#839496"), .hex("#6c71c4"), .hex("#93a1a1"), .hex("#fdf6e3")
    ]
    static let solarizedLightAnsi: [CodableColor] = [
        .hex("#eee8d5"), .hex("#dc322f"), .hex("#859900"), .hex("#b58900"),
        .hex("#268bd2"), .hex("#d33682"), .hex("#2aa198"), .hex("#073642"),
        .hex("#fdf6e3"), .hex("#cb4b16"), .hex("#93a1a1"), .hex("#839496"),
        .hex("#657b83"), .hex("#6c71c4"), .hex("#586e75"), .hex("#002b36")
    ]
    static let monokaiAnsi: [CodableColor] = [
        .hex("#272822"), .hex("#f92672"), .hex("#a6e22e"), .hex("#f4bf75"),
        .hex("#66d9e8"), .hex("#ae81ff"), .hex("#a1efe4"), .hex("#f8f8f2"),
        .hex("#75715e"), .hex("#f92672"), .hex("#a6e22e"), .hex("#f4bf75"),
        .hex("#66d9e8"), .hex("#ae81ff"), .hex("#a1efe4"), .hex("#f9f8f5")
    ]
    static let gruvboxAnsi: [CodableColor] = [
        .hex("#282828"), .hex("#cc241d"), .hex("#98971a"), .hex("#d79921"),
        .hex("#458588"), .hex("#b16286"), .hex("#689d6a"), .hex("#a89984"),
        .hex("#928374"), .hex("#fb4934"), .hex("#b8bb26"), .hex("#fabd2f"),
        .hex("#83a598"), .hex("#d3869b"), .hex("#8ec07c"), .hex("#ebdbb2")
    ]
}
