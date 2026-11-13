import Foundation

/// LaTeX math as text the book view can show without a math engine: Greek letters and symbols as
/// Unicode, `^` and `_` as raised and lowered runs, `\frac{a}{b}` as a/b, `\mathbb{R}` as ℝ,
/// variables in italics, numbers and function names upright. Unknown commands stay as written.
public enum MathText {
    public struct Run: Equatable, Sendable {
        public enum Style: Equatable, Sendable { case italic, upright, bold }
        public var text: String
        public var style: Style
        /// Superscript depth (> 0) or subscript depth (< 0) is `shift`; 0 is the baseline.
        public var shift: Int
        /// How many script levels deep (smaller text).
        public var level: Int

        public init(_ text: String, _ style: Style = .upright, shift: Int = 0, level: Int = 0) {
            self.text = text
            self.style = style
            self.shift = shift
            self.level = level
        }
    }

    /// The runs of `latex`, neighbouring runs of the same kind merged.
    public static func runs(_ latex: String) -> [Run] {
        var parser = Parser(Array(latex))
        var runs: [Run] = []
        parser.expression(into: &runs, style: nil, shift: 0, level: 0, until: nil)
        // `aligned` and friends: rows become lines, columns spaces.
        var merged: [Run] = []
        for run in runs where !run.text.isEmpty {
            if let last = merged.last, last.style == run.style, last.shift == run.shift, last.level == run.level {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        // Trim spaces at the ends of the whole formula and of its lines.
        if let first = merged.first, first.text.hasPrefix(" ") { merged[0].text = String(first.text.drop { $0 == " " }) }
        if let last = merged.last, last.text.hasSuffix(" ") {
            merged[merged.count - 1].text = String(last.text.reversed().drop { $0 == " " }.reversed())
        }
        return merged.filter { !$0.text.isEmpty }
    }

    /// The formula as plain text (for tests and tooltips).
    public static func plain(_ latex: String) -> String {
        runs(latex).map(\.text).joined()
    }

    // MARK: Tables

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    static let symbols: [String: String] = [
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "•",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼",
        "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫", "prec": "≺", "succ": "≻",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔",
        "Leftrightarrow": "⇔", "iff": "⇔", "implies": "⇒", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
        "oint": "∮", "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "bigcup": "⋃", "bigcap": "⋂", "setminus": "∖", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨",
        "oplus": "⊕", "otimes": "⊗", "top": "⊤", "bot": "⊥", "perp": "⊥", "parallel": "∥", "mid": "|", "vert": "|",
        "Vert": "‖", "|": "‖", "angle": "∠", "triangle": "△", "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮",
        "ddots": "⋱", "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
        "{": "{", "}": "}", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_", "prime": "′", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "deg": "°", "dagger": "†", "checkmark": "✓",
        ",": "\u{2009}", ";": "\u{2005}", ":": "\u{2005}", "!": "", " ": " ", "quad": "\u{2003}", "qquad": "\u{2003}\u{2003}",
        "\\": "\n", "cr": "\n",
    ]

    /// Symbols set with space around them.
    static let relations: Set<String> = [
        "le", "leq", "ge", "geq", "neq", "ne", "approx", "equiv", "sim", "simeq", "cong", "propto", "ll", "gg", "prec", "succ",
        "to", "rightarrow", "leftarrow", "Rightarrow", "Leftarrow", "leftrightarrow", "Leftrightarrow", "iff", "implies", "mapsto",
        "in", "notin", "ni", "subset", "supset", "subseteq", "supseteq", "mid",
    ]

    /// Shown upright, as words: `\sin x`.
    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "log", "ln", "lg",
        "exp", "max", "min", "sup", "inf", "lim", "liminf", "limsup", "det", "dim", "ker", "arg", "deg", "gcd", "Pr", "tr",
        "rank", "diag", "sgn",
    ]

    /// Commands that only size or space delimiters; their argument (if a delimiter) stays.
    static let ignored: Set<String> = [
        "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "middle", "displaystyle", "textstyle",
        "scriptstyle", "limits", "nolimits", "nonumber", "notag", "label", "tag", "begin", "end", "phantom",
    ]

    static let accents: [String: String] = [
        "hat": "\u{302}", "widehat": "\u{302}", "bar": "\u{304}", "overline": "\u{305}", "vec": "\u{20D7}", "tilde": "\u{303}",
        "widetilde": "\u{303}", "dot": "\u{307}", "ddot": "\u{308}", "check": "\u{30C}", "breve": "\u{306}", "acute": "\u{301}",
        "grave": "\u{300}", "underline": "\u{332}",
    ]

    /// A letter in a Unicode mathematical alphabet.
    static func styled(_ text: String, alphabet: String) -> String {
        let special: [String: [Character: String]] = [
            "mathbb": ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"],
            "mathcal": ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ", "e": "ℯ", "g": "ℊ", "o": "ℴ"],
            "mathfrak": ["C": "ℭ", "H": "ℌ", "I": "ℑ", "R": "ℜ", "Z": "ℨ"],
        ]
        let bases: [String: (upper: UInt32, lower: UInt32?, digit: UInt32?)] = [
            "mathbb": (0x1D538, 0x1D552, 0x1D7D8), "mathcal": (0x1D49C, 0x1D4B6, nil), "mathfrak": (0x1D504, 0x1D51E, nil),
            "mathscr": (0x1D49C, 0x1D4B6, nil), "mathsf": (0x1D5A0, 0x1D5BA, 0x1D7E2), "mathtt": (0x1D670, 0x1D68A, 0x1D7F6),
        ]
        guard let base = bases[alphabet] else { return text }
        return text.map { character -> String in
            if let replaced = special[alphabet]?[character] { return replaced }
            guard let ascii = character.asciiValue else { return String(character) }
            let scalar: UInt32?
            switch ascii {
            case 65...90: scalar = base.upper + UInt32(ascii - 65)
            case 97...122: scalar = base.lower.map { $0 + UInt32(ascii - 97) }
            case 48...57: scalar = base.digit.map { $0 + UInt32(ascii - 48) }
            default: scalar = nil
            }
            return scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(character)
        }.joined()
    }

    // MARK: Parsing

    struct Parser {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) {
            self.chars = chars
        }

        var atEnd: Bool { i >= chars.count }

        mutating func command() -> String {
            // After the backslash: letters, or one other character.
            var name = ""
            if i < chars.count, chars[i].isLetter {
                while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
                // `\alpha x`: the space after a command name is not a space in the formula.
                while i < chars.count, chars[i] == " " { i += 1 }
            } else if i < chars.count {
                name = String(chars[i])
                i += 1
            }
            return name
        }

        /// The raw text of a `{…}` group (or one character), for `\text`, `\begin` and similar.
        mutating func rawGroup() -> String {
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count else { return "" }
            if chars[i] != "{" {
                defer { i += 1 }
                return String(chars[i])
            }
            var depth = 0
            var text = ""
            while i < chars.count {
                let c = chars[i]
                i += 1
                if c == "{" { depth += 1; if depth == 1 { continue } }
                if c == "}" { depth -= 1; if depth == 0 { break } }
                text.append(c)
            }
            return text
        }

        /// One argument: a group or a single atom, as runs.
        mutating func argument(style: Run.Style?, shift: Int, level: Int) -> [Run] {
            while i < chars.count, chars[i] == " " { i += 1 }
            var runs: [Run] = []
            guard i < chars.count else { return runs }
            if chars[i] == "{" {
                i += 1
                expression(into: &runs, style: style, shift: shift, level: level, until: "}")
            } else {
                atom(into: &runs, style: style, shift: shift, level: level)
            }
            return runs
        }

        mutating func expression(into runs: inout [Run], style: Run.Style?, shift: Int, level: Int, until end: Character?) {
            while i < chars.count {
                if let end, chars[i] == end {
                    i += 1
                    return
                }
                atom(into: &runs, style: style, shift: shift, level: level)
            }
        }

        /// Whether a + or − here joins two terms: something on the same level comes before it that is
        /// not an operator or an opening bracket.
        static func isBinary(after runs: [Run], shift: Int, level: Int) -> Bool {
            guard let last = runs.last(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }),
                  let character = last.text.trimmingCharacters(in: .whitespaces).last else { return false }
            return !"([{=+−×·,/<>≤≥≠≈→∈|⟨\u{2003}".contains(character)
        }

        mutating func atom(into runs: inout [Run], style: Run.Style?, shift: Int, level: Int) {
            let c = chars[i]
            i += 1
            func add(_ text: String, _ natural: Run.Style) {
                runs.append(Run(text, style ?? natural, shift: shift, level: level))
            }
            switch c {
            case "{":
                expression(into: &runs, style: style, shift: shift, level: level, until: "}")
            case "}":
                break
            case "^", "_":
                let up = c == "^"
                runs += argument(style: style, shift: shift + (up ? 1 : -1), level: level + 1)
            case "\\":
                let name = command()
                if let symbol = MathText.greek[name] {
                    add(symbol, name.first?.isUppercase == true ? .upright : .italic)
                } else if let symbol = MathText.symbols[name] {
                    // Relations and arrows get space around them, as in typeset math.
                    add(MathText.relations.contains(name) ? "\u{2005}\(symbol)\u{2005}" : symbol, .upright)
                } else if MathText.functions.contains(name) {
                    add(name, .upright)
                    // A space before what follows, unless a script follows.
                    if i < chars.count, chars[i] != "^", chars[i] != "_" { add("\u{2009}", .upright) }
                } else if name == "frac" || name == "dfrac" || name == "tfrac" || name == "cfrac" {
                    let numerator = argument(style: style, shift: shift, level: level)
                    let denominator = argument(style: style, shift: shift, level: level)
                    func wrapped(_ part: [Run]) -> [Run] {
                        let text = part.map(\.text).joined()
                        let simple = text.count <= 1 || text.allSatisfy { $0.isNumber || $0 == "." }
                        return simple ? part : [Run("(", .upright, shift: shift, level: level)] + part + [Run(")", .upright, shift: shift, level: level)]
                    }
                    runs += wrapped(numerator) + [Run("/", .upright, shift: shift, level: level)] + wrapped(denominator)
                    // Keep "½x" from reading as "1/(2x)".
                    if i < chars.count, chars[i] != "}" { add("\u{2009}", .upright) }
                } else if name == "sqrt" {
                    if i < chars.count, chars[i] == "[" {
                        // \sqrt[n]{x}: the index raised before the root.
                        i += 1
                        var index = ""
                        while i < chars.count, chars[i] != "]" { index.append(chars[i]); i += 1 }
                        i += 1
                        runs.append(Run(index, .upright, shift: shift + 1, level: level + 1))
                    }
                    let inner = argument(style: style, shift: shift, level: level)
                    let text = inner.map(\.text).joined()
                    add("√", .upright)
                    runs += text.count <= 1 ? inner : [Run("(", .upright, shift: shift, level: level)] + inner + [Run(")", .upright, shift: shift, level: level)]
                } else if ["text", "textrm", "mathrm", "operatorname", "textup", "mbox", "textnormal"].contains(name) {
                    add(rawGroup(), .upright)
                } else if ["mathbf", "boldsymbol", "bm", "textbf", "pmb"].contains(name) {
                    runs += argument(style: .bold, shift: shift, level: level)
                } else if ["mathit", "textit", "emph"].contains(name) {
                    runs += argument(style: .italic, shift: shift, level: level)
                } else if ["mathbb", "mathcal", "mathfrak", "mathscr", "mathsf", "mathtt"].contains(name) {
                    add(MathText.styled(rawGroup(), alphabet: name), .upright)
                } else if let mark = MathText.accents[name] {
                    let inner = argument(style: style, shift: shift, level: level)
                    runs += inner
                    if let last = runs.indices.last { runs[last].text += mark }
                } else if name == "begin" || name == "end" {
                    _ = rawGroup() // aligned, matrix, cases, …
                } else if MathText.ignored.contains(name) {
                    if name == "label" || name == "tag" { _ = rawGroup() }
                } else if name.isEmpty {
                    break
                } else {
                    add("\\" + name, .upright)
                }
            case "&":
                break // alignment points of aligned rows
            case "~":
                add(" ", .upright)
            case " ", "\n", "\t":
                break // spacing in math comes from the symbols
            case "'":
                add("′", .upright)
            case "-", "+":
                // A real minus; spaced as an operator between two terms, not as a sign ("−1", "e⁻ᵗ").
                let sign = c == "-" ? "−" : "+"
                add(Self.isBinary(after: runs, shift: shift, level: level) ? "\u{2005}\(sign)\u{2005}" : sign, .upright)
            case "=", "<", ">", "*":
                add("\u{2005}\(c == "*" ? "∗" : String(c))\u{2005}", .upright)
            default:
                add(String(c), c.isLetter ? .italic : .upright)
            }
        }
    }
}
