import AppKit
import Observation

/// How the editor looks, set in Settings › Editor and kept in the user defaults. Editors listen for
/// `EditorSettings.didChange` and restyle their text.
@MainActor
@Observable
final class EditorSettings {
    static let shared = EditorSettings()
    static let didChange = Notification.Name("EditorSettingsDidChange")

    /// The app's light or dark look.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// Colours for MyST syntax. Every theme works in light and dark mode.
    enum Theme: String, CaseIterable, Identifiable {
        case calm, ocean, forest, ink
        /// The user's own colours (`customColors`).
        case custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .calm: return "Calm (purple and teal)"
            case .ocean: return "Ocean (blue and orange)"
            case .forest: return "Forest (green and brown)"
            case .ink: return "Ink (no colours)"
            case .custom: return "Custom"
            }
        }

        var accent: NSColor {
            switch self {
            case .calm, .custom: return .systemPurple
            case .ocean: return .systemBlue
            case .forest: return .systemGreen
            case .ink: return .labelColor
            }
        }

        var math: NSColor {
            switch self {
            case .calm, .custom: return .systemTeal
            case .ocean: return .systemOrange
            case .forest: return .systemBrown
            case .ink: return .secondaryLabelColor
            }
        }

        /// Admonitions get their own colours only in the colourful themes.
        var colorsAdmonitions: Bool { self != .ink }
    }

    /// A font family; empty means the system's monospaced font (SF Mono).
    var fontName: String { didSet { changed("editor.fontName", fontName) } }
    var fontSize: Double { didSet { changed("editor.fontSize", fontSize) } }
    /// Line height as a multiple of the font's (1 = tight, 1.5 = airy).
    var lineHeight: Double { didSet { changed("editor.lineHeight", lineHeight) } }
    var showsLineNumbers: Bool { didSet { changed("editor.lineNumbers", showsLineNumbers) } }
    /// Triangles left of the text that fold directives and code cells.
    var showsFoldMarkers: Bool { didSet { changed("editor.foldMarkers", showsFoldMarkers) } }
    /// Pages open with their YAML front matter folded to its first line.
    var hidesFrontMatter: Bool { didSet { changed("editor.hideFrontMatter", hidesFrontMatter) } }
    /// Directive options (`:label:`, `:width:` …) are folded into their opening line.
    var hidesDirectiveOptions: Bool { didSet { changed("editor.hideOptions", hidesDirectiveOptions) } }
    var theme: Theme { didSet { changed("editor.theme", theme.rawValue) } }
    /// The colours of the Custom theme, light and dark for each role.
    var customColors: SyntaxColors {
        didSet { changed("editor.customColors", (try? JSONEncoder().encode(customColors)) ?? Data()) }
    }
    /// The author new projects start with; empty leaves the field empty.
    var defaultAuthor: String { didSet { changed("app.defaultAuthor", defaultAuthor) } }
    /// Limit lines to `readableColumns` characters, centred, also outside focus mode.
    var limitsLineWidth: Bool { didSet { changed("editor.limitWidth", limitsLineWidth) } }
    var readableColumns: Double { didSet { changed("editor.columns", readableColumns) } }
    /// In focus mode, everything but the paragraph with the cursor is dimmed.
    var dimsInFocusMode: Bool { didSet { changed("editor.focusDims", dimsInFocusMode) } }
    var appearance: Appearance {
        didSet {
            changed("app.appearance", appearance.rawValue)
            applyAppearance()
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        fontName = defaults.string(forKey: "editor.fontName") ?? ""
        fontSize = defaults.object(forKey: "editor.fontSize") as? Double ?? 13
        lineHeight = defaults.object(forKey: "editor.lineHeight") as? Double ?? 1.15
        showsLineNumbers = defaults.bool(forKey: "editor.lineNumbers")
        showsFoldMarkers = defaults.object(forKey: "editor.foldMarkers") as? Bool ?? true
        hidesFrontMatter = defaults.bool(forKey: "editor.hideFrontMatter")
        hidesDirectiveOptions = defaults.bool(forKey: "editor.hideOptions")
        theme = Theme(rawValue: defaults.string(forKey: "editor.theme") ?? "") ?? .calm
        customColors = defaults.data(forKey: "editor.customColors").flatMap { try? JSONDecoder().decode(SyntaxColors.self, from: $0) } ?? SyntaxColors()
        defaultAuthor = defaults.string(forKey: "app.defaultAuthor") ?? ""
        limitsLineWidth = defaults.bool(forKey: "editor.limitWidth")
        readableColumns = defaults.object(forKey: "editor.columns") as? Double ?? 80
        dimsInFocusMode = defaults.object(forKey: "editor.focusDims") as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: "app.appearance") ?? "") ?? .system
    }

    private func changed(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        fontCache = [:]
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func resetToDefaults() {
        apply(Snapshot())
    }

    // MARK: Colours

    /// Code on a tinted background, in light and dark mode. A dynamic colour never changes after it is
    /// made, so built-in themes may read it from any thread.
    nonisolated static let defaultCodeBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.black.withAlphaComponent(0.045)
    }

    /// The colour of `role` in the chosen theme; the Custom theme falls back to Calm for roles it lacks.
    func color(_ role: SyntaxRole) -> NSColor {
        if theme == .custom, let color = customColors.color(role) { return color }
        return theme.color(role)
    }

    /// Whether admonitions get their own colours (not in Ink).
    var colorsAdmonitions: Bool { theme.colorsAdmonitions }

    // MARK: Saving and loading

    /// Everything on Settings › Editor, for a settings file. Missing values read as the defaults.
    struct Snapshot: Codable {
        var fontName = ""
        var fontSize = 13.0
        var lineHeight = 1.15
        var showsLineNumbers = false
        var showsFoldMarkers = true
        var hidesFrontMatter = false
        var hidesDirectiveOptions = false
        var theme = Theme.calm.rawValue
        var customColors = SyntaxColors()
        var limitsLineWidth = false
        var readableColumns = 80.0
        var dimsInFocusMode = true
        var appearance = Appearance.system.rawValue
        var defaultAuthor = ""

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Snapshot()
            fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
            fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
            lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? d.lineHeight
            showsLineNumbers = try c.decodeIfPresent(Bool.self, forKey: .showsLineNumbers) ?? d.showsLineNumbers
            showsFoldMarkers = try c.decodeIfPresent(Bool.self, forKey: .showsFoldMarkers) ?? d.showsFoldMarkers
            hidesFrontMatter = try c.decodeIfPresent(Bool.self, forKey: .hidesFrontMatter) ?? d.hidesFrontMatter
            hidesDirectiveOptions = try c.decodeIfPresent(Bool.self, forKey: .hidesDirectiveOptions) ?? d.hidesDirectiveOptions
            theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
            customColors = try c.decodeIfPresent(SyntaxColors.self, forKey: .customColors) ?? d.customColors
            limitsLineWidth = try c.decodeIfPresent(Bool.self, forKey: .limitsLineWidth) ?? d.limitsLineWidth
            readableColumns = try c.decodeIfPresent(Double.self, forKey: .readableColumns) ?? d.readableColumns
            dimsInFocusMode = try c.decodeIfPresent(Bool.self, forKey: .dimsInFocusMode) ?? d.dimsInFocusMode
            appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
            defaultAuthor = try c.decodeIfPresent(String.self, forKey: .defaultAuthor) ?? d.defaultAuthor
        }
    }

    var snapshot: Snapshot {
        var s = Snapshot()
        s.fontName = fontName
        s.fontSize = fontSize
        s.lineHeight = lineHeight
        s.showsLineNumbers = showsLineNumbers
        s.showsFoldMarkers = showsFoldMarkers
        s.hidesFrontMatter = hidesFrontMatter
        s.hidesDirectiveOptions = hidesDirectiveOptions
        s.theme = theme.rawValue
        s.customColors = customColors
        s.limitsLineWidth = limitsLineWidth
        s.readableColumns = readableColumns
        s.dimsInFocusMode = dimsInFocusMode
        s.appearance = appearance.rawValue
        s.defaultAuthor = defaultAuthor
        return s
    }

    func apply(_ s: Snapshot) {
        fontName = s.fontName
        fontSize = min(22, max(10, s.fontSize))
        lineHeight = min(1.8, max(1, s.lineHeight))
        showsLineNumbers = s.showsLineNumbers
        showsFoldMarkers = s.showsFoldMarkers
        hidesFrontMatter = s.hidesFrontMatter
        hidesDirectiveOptions = s.hidesDirectiveOptions
        customColors = s.customColors
        theme = Theme(rawValue: s.theme) ?? .calm
        limitsLineWidth = s.limitsLineWidth
        readableColumns = min(120, max(50, s.readableColumns))
        dimsInFocusMode = s.dimsInFocusMode
        appearance = Appearance(rawValue: s.appearance) ?? .system
        defaultAuthor = s.defaultAuthor
    }

    /// The settings as a JSON file's contents.
    func exported() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// Applies a settings file written by `exported()`.
    func load(_ data: Data) throws {
        apply(try JSONDecoder().decode(Snapshot.self, from: data))
    }

    // MARK: Fonts

    @ObservationIgnored private var fontCache: [String: NSFont] = [:]

    /// The editor font at `scale` times the chosen size, in `weight`, optionally italic.
    func font(scale: CGFloat = 1, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let size = (CGFloat(fontSize) * scale).rounded()
        let key = "\(size)-\(weight.rawValue)-\(italic)"
        if let cached = fontCache[key] { return cached }
        var font: NSFont
        let bold = weight >= .semibold
        if !fontName.isEmpty,
           let family = NSFontManager.shared.font(withFamily: fontName, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size) {
            font = family
        } else {
            font = .monospacedSystemFont(ofSize: size, weight: weight)
        }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        fontCache[key] = font
        return font
    }

    /// Width of one character of the regular font, for line numbers and the readable width.
    var characterWidth: CGFloat {
        let font = font()
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// Fixed-pitch font families installed on this Mac, for the font menu.
    static var monospacedFamilies: [String] {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }.sorted()
    }
}
