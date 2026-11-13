import AppKit
import SwiftUI

/// What the editor colours, each with its own colour in the syntax colours.
enum SyntaxRole: String, CaseIterable, Codable, Identifiable {
    case directive, math, link, marker, secondary, codeBackground
    case note, tip, important, warning, danger

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directive: return "Directives, roles and YAML keys"
        case .math: return "Math"
        case .link: return "Link text"
        case .marker: return "Markers, comments, front matter"
        case .secondary: return "Option values, link targets, strings"
        case .codeBackground: return "Code background"
        case .note: return "Note, see also"
        case .tip: return "Tip, hint"
        case .important: return "Important"
        case .warning: return "Warning, caution, attention"
        case .danger: return "Danger, error"
        }
    }

    /// The admonition roles, by directive name.
    static func admonition(_ name: String) -> SyntaxRole? {
        switch name {
        case "note", "admonition", "seealso": return .note
        case "tip", "hint": return .tip
        case "important": return .important
        case "attention", "caution", "warning": return .warning
        case "danger", "error": return .danger
        default: return nil
        }
    }
}

/// A colour as stored in the settings (sRGB, 0…1).
struct RGBA: Codable, Equatable {
    var red: Double, green: Double, blue: Double, alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// `color` as it looks in light (`dark` false) or dark mode.
    static func resolve(_ color: NSColor, dark: Bool) -> RGBA {
        var result = RGBA(red: 0, green: 0, blue: 0)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { result = RGBA(color) }
        return result
    }
}

/// The user's own syntax colours: for each role a colour in light and one in dark mode.
struct SyntaxColors: Codable, Equatable {
    struct Pair: Codable, Equatable {
        var light: RGBA
        var dark: RGBA
    }

    /// By role name, so a file from another version still reads.
    var pairs: [String: Pair] = [:]

    subscript(role: SyntaxRole) -> Pair? {
        get { pairs[role.rawValue] }
        set { pairs[role.rawValue] = newValue }
    }

    /// The colours of a built-in theme, to start editing from.
    static func from(_ theme: EditorSettings.Theme) -> SyntaxColors {
        var colors = SyntaxColors()
        for role in SyntaxRole.allCases {
            let color = theme.color(role)
            colors[role] = Pair(light: .resolve(color, dark: false), dark: .resolve(color, dark: true))
        }
        return colors
    }

    /// The colour of `role`: light or dark with the appearance it is drawn in.
    func color(_ role: SyntaxRole) -> NSColor? {
        guard let pair = self[role] else { return nil }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.dark.nsColor : pair.light.nsColor
        }
    }
}

extension EditorSettings.Theme {
    /// The colour of `role` in this built-in theme (system colours, light and dark).
    func color(_ role: SyntaxRole) -> NSColor {
        switch role {
        case .directive: return accent
        case .math: return math
        case .link: return .linkColor
        case .marker: return .tertiaryLabelColor
        case .secondary: return .secondaryLabelColor
        case .codeBackground: return EditorSettings.defaultCodeBackground
        case .note: return colorsAdmonitions ? .systemBlue : accent
        case .tip: return colorsAdmonitions ? .systemGreen : accent
        case .important: return colorsAdmonitions ? .systemIndigo : accent
        case .warning: return colorsAdmonitions ? .systemOrange : accent
        case .danger: return colorsAdmonitions ? .systemRed : accent
        }
    }
}

/// Settings › Editor › Edit Colours…: a light and a dark colour for each role, with a preview.
/// Changing a colour switches to the Custom theme, starting from the theme that was chosen.
struct SyntaxColorsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = EditorSettings.shared
    @State private var previewsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Syntax Colours").font(.title2.weight(.semibold))
                        Spacer()
                        Menu("Start from") {
                            ForEach(EditorSettings.Theme.allCases.filter { $0 != .custom }) { theme in
                                Button(theme.title) {
                                    settings.customColors = .from(theme)
                                    settings.theme = .custom
                                }
                            }
                        }
                        .fixedSize()
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow {
                            Text("")
                            Text("Light").font(.caption).foregroundStyle(.secondary)
                            Text("Dark").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(SyntaxRole.allCases) { role in
                            GridRow {
                                Text(role.title)
                                ColorPicker("", selection: binding(role, dark: false), supportsOpacity: true).labelsHidden()
                                ColorPicker("", selection: binding(role, dark: true), supportsOpacity: true).labelsHidden()
                            }
                        }
                    }
                    Text(settings.theme == .custom
                         ? "Custom colours, saved with the other settings."
                         : "Showing \(settings.theme.title). Changing a colour makes a custom theme from it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 400)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Preview").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $previewsDark) {
                            Text("Light").tag(false)
                            Text("Dark").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    SamplePreview(dark: previewsDark)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }
            }
            .padding(20)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 860, height: 560)
    }

    private func binding(_ role: SyntaxRole, dark: Bool) -> Binding<Color> {
        Binding(
            get: {
                let pair = settings.theme == .custom ? settings.customColors[role] : nil
                let rgba = pair.map { dark ? $0.dark : $0.light } ?? .resolve(settings.theme.color(role), dark: dark)
                return Color(nsColor: rgba.nsColor)
            },
            set: { color in
                if settings.theme != .custom {
                    settings.customColors = .from(settings.theme)
                    settings.theme = .custom
                }
                var colors = settings.customColors
                var pair = colors[role] ?? SyntaxColors.Pair(light: .resolve(.textColor, dark: false), dark: .resolve(.textColor, dark: true))
                if dark { pair.dark = RGBA(NSColor(color)) } else { pair.light = RGBA(NSColor(color)) }
                colors[role] = pair
                settings.customColors = colors
            }
        )
    }
}
