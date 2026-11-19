import AppKit
import SwiftTerm

/// Terminal color scheme, similar to a Terminal.app profile.
struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor
    /// 16 ANSI colors: 0–7 normal, 8–15 bright.
    let ansi: [NSColor]
    /// Border highlight color of the focused pane.
    let accent: NSColor

    static func == (a: TerminalTheme, b: TerminalTheme) -> Bool { a.id == b.id }

    var isLight: Bool {
        let c = background.usingColorSpace(.sRGB) ?? background
        return (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) > 0.6
    }

    var swiftTermPalette: [SwiftTerm.Color] {
        ansi.map { c in
            let s = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(s.redComponent * 65535),
                                   green: UInt16(s.greenComponent * 65535),
                                   blue: UInt16(s.blueComponent * 65535))
        }
    }

    /// Same scheme with a custom background color.
    func withBackground(_ bg: NSColor) -> TerminalTheme {
        let light = TerminalTheme.luma(bg) > 0.6
        return TerminalTheme(id: id, name: name, background: bg,
                             foreground: light ? NSColor(hex: "1d1f21")! : foreground,
                             cursor: light ? NSColor(hex: "1d1f21")! : cursor,
                             selection: light ? NSColor(hex: "b4d5fe")! : selection,
                             ansi: light ? TerminalTheme.paper.ansi : ansi,
                             accent: accent)
    }

    static func luma(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}

extension TerminalTheme {
    private static func palette(_ hex: [String]) -> [NSColor] { hex.map { NSColor(hex: $0)! } }

    private static let standardDark = palette([
        "1d1f21", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "c5c8c6",
        "5c6370", "ff7a85", "b5e890", "ffd88a", "7cc4ff", "dd96f0", "6fd4e0", "ffffff",
    ])

    static let graphite = TerminalTheme(
        id: "graphite", name: "Graphite",
        background: NSColor(hex: "1c1d21")!, foreground: NSColor(hex: "d7dae0")!,
        cursor: NSColor(hex: "d7dae0")!, selection: NSColor(hex: "3a3f4b")!,
        ansi: standardDark, accent: NSColor(hex: "8ab4f8")!)

    static let pro = TerminalTheme(
        id: "pro", name: "Black",
        background: NSColor(hex: "000000")!, foreground: NSColor(hex: "f2f2f2")!,
        cursor: NSColor(hex: "a0a0a0")!, selection: NSColor(hex: "414141")!,
        ansi: standardDark, accent: NSColor(hex: "c8c8c8")!)

    static let ocean = TerminalTheme(
        id: "ocean", name: "Ocean",
        background: NSColor(hex: "0f2a4a")!, foreground: NSColor(hex: "e6f0ff")!,
        cursor: NSColor(hex: "7fd1ff")!, selection: NSColor(hex: "24507f")!,
        ansi: palette(["0b1c30", "ff6b81", "7ee0a1", "ffd479", "6cb6ff", "c792ea", "5fe1e6", "dbe7f5",
                       "4a6a8a", "ff8fa0", "a2f0bf", "ffe3a3", "9ccfff", "dcb3f5", "8ef0f3", "ffffff"]),
        accent: NSColor(hex: "5fb8ff")!)

    static let forest = TerminalTheme(
        id: "forest", name: "Forest",
        background: NSColor(hex: "13261b")!, foreground: NSColor(hex: "d8ecd8")!,
        cursor: NSColor(hex: "8fdc8f")!, selection: NSColor(hex: "2c4f37")!,
        ansi: palette(["0c1a12", "e57373", "8fdc8f", "e6d27a", "79b8d6", "c39ad6", "6fcfb8", "d0e4d0",
                       "4f6b57", "ff9a9a", "b3f0b3", "f5e49c", "a0d4ee", "dbbcea", "93e6d2", "ffffff"]),
        accent: NSColor(hex: "6fd08c")!)

    static let matrix = TerminalTheme(
        id: "matrix", name: "Green Phosphor",
        background: NSColor(hex: "000000")!, foreground: NSColor(hex: "28fe14")!,
        cursor: NSColor(hex: "38fe27")!, selection: NSColor(hex: "0d4a0d")!,
        ansi: palette(["000000", "990000", "00a600", "999900", "0000b2", "b200b2", "00a6b2", "bfbfbf",
                       "666666", "e50000", "00d900", "e5e500", "0000ff", "e500e5", "00e5e5", "e5e5e5"]),
        accent: NSColor(hex: "28fe14")!)

    static let desert = TerminalTheme(
        id: "desert", name: "Red Sands",
        background: NSColor(hex: "7a2b1b")!, foreground: NSColor(hex: "d7c9a7")!,
        cursor: NSColor(hex: "ffffff")!, selection: NSColor(hex: "a14a35")!,
        ansi: palette(["000000", "ff3f00", "00bb00", "e7b000", "0072ff", "bb00bb", "00bbbb", "bbbbbb",
                       "555555", "bb0000", "00bb00", "e7b000", "0072ae", "ff55ff", "55ffff", "ffffff"]),
        accent: NSColor(hex: "ffb070")!)

    static let plum = TerminalTheme(
        id: "plum", name: "Plum",
        background: NSColor(hex: "2a1b3d")!, foreground: NSColor(hex: "eadcf7")!,
        cursor: NSColor(hex: "f0a6ff")!, selection: NSColor(hex: "4b3270")!,
        ansi: palette(["1a1027", "ff6e9c", "9ce39c", "ffd98a", "8fb1ff", "d9a2ff", "7fe0e0", "e0d4ee",
                       "6b5a80", "ff94b6", "bdf2bd", "ffe8b3", "b3caff", "e8c4ff", "a6efef", "ffffff"]),
        accent: NSColor(hex: "d68cff")!)

    static let ember = TerminalTheme(
        id: "ember", name: "Ember",
        background: NSColor(hex: "241a14")!, foreground: NSColor(hex: "f1e1cf")!,
        cursor: NSColor(hex: "ff9f43")!, selection: NSColor(hex: "4a3526")!,
        ansi: palette(["1a120d", "ef6b5b", "a9d47c", "f7c26b", "7fb2e5", "d39be0", "79d0c0", "e8d8c6",
                       "6f5a4b", "ff8f80", "c5ea9e", "ffd895", "a5cdf5", "e6bdee", "a0e5d8", "ffffff"]),
        accent: NSColor(hex: "ff9f43")!)

    static let solarDark = TerminalTheme(
        id: "solarDark", name: "Solar Dark",
        background: NSColor(hex: "002b36")!, foreground: NSColor(hex: "93a1a1")!,
        cursor: NSColor(hex: "93a1a1")!, selection: NSColor(hex: "073642")!,
        ansi: palette(["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                       "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]),
        accent: NSColor(hex: "2aa198")!)

    static let solarLight = TerminalTheme(
        id: "solarLight", name: "Solar Light",
        background: NSColor(hex: "fdf6e3")!, foreground: NSColor(hex: "586e75")!,
        cursor: NSColor(hex: "586e75")!, selection: NSColor(hex: "eee8d5")!,
        ansi: palette(["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                       "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]),
        accent: NSColor(hex: "b58900")!)

    static let paper = TerminalTheme(
        id: "paper", name: "Paper",
        background: NSColor(hex: "fbfaf7")!, foreground: NSColor(hex: "1d1f21")!,
        cursor: NSColor(hex: "1d1f21")!, selection: NSColor(hex: "b4d5fe")!,
        ansi: palette(["000000", "c41a16", "007400", "826b28", "0e4fd3", "a90d91", "1c7f8a", "8e8e8e",
                       "5c5c5c", "e0322b", "1f9a1f", "a0882c", "3a74f0", "c43bb0", "2e9aa6", "1d1f21"]),
        accent: NSColor(hex: "0e6fff")!)

    static let novel = TerminalTheme(
        id: "novel", name: "Novel",
        background: NSColor(hex: "dfdbc3")!, foreground: NSColor(hex: "3b2322")!,
        cursor: NSColor(hex: "73635a")!, selection: NSColor(hex: "a4a390")!,
        ansi: palette(["000000", "cc0000", "009600", "d06b00", "0000cc", "cc00cc", "0087cc", "cccccc",
                       "808080", "cc0000", "009600", "d06b00", "0000cc", "cc00cc", "0087cc", "ffffff"]),
        accent: NSColor(hex: "8b5a2b")!)

    static let all: [TerminalTheme] = [graphite, pro, ocean, forest, matrix, desert, plum, ember,
                                       solarDark, solarLight, paper, novel]

    static func byId(_ id: String?) -> TerminalTheme {
        all.first { $0.id == id } ?? graphite
    }
}

/// Colored border labels (like Finder tags).
enum BorderLabel: String, CaseIterable, Codable {
    case none, red, orange, yellow, green, blue, purple, pink

    var title: String {
        switch self {
        case .none: return "None"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    var color: NSColor? {
        switch self {
        case .none: return nil
        case .red: return NSColor(hex: "ff5f57")
        case .orange: return NSColor(hex: "ff9f0a")
        case .yellow: return NSColor(hex: "ffd60a")
        case .green: return NSColor(hex: "32d74b")
        case .blue: return NSColor(hex: "0a84ff")
        case .purple: return NSColor(hex: "bf5af2")
        case .pink: return NSColor(hex: "ff6482")
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "%02x%02x%02x",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
