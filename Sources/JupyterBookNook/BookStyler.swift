import AppKit
import CoreText
import MystSyntax

/// The book view of a page (View › Book View): the same text, styled like the finished book. Prose
/// is set in a serif reading font, headings in real sizes, and markup (`##`, `**`, backticks,
/// link targets, role names, labels, comments, front matter) is hidden. The paragraph with the
/// cursor shows its markup again, so everything stays editable. Nothing is written to the file:
/// the attributes are the editor's, and hiding is done by `FoldingLayoutManager`.
@MainActor
enum BookStyler {
    /// What can be hidden, and newlines that are shown as spaces (a Markdown paragraph written on
    /// several lines is one paragraph in the book).
    struct Presentation {
        var hideable = IndexSet()
        var joins = IndexSet()
        /// Boxes, panels and figures drawn behind the text.
        var boxes: [BookBox] = []
        /// Math and references shown as other text, by their first character.
        var replacements: [Int: BookReplacement] = [:]

        /// What is hidden while the cursor is in `revealed`.
        func hidden(revealed: NSRange) -> (hidden: IndexSet, joins: IndexSet, replacements: [Int: BookReplacement]) {
            guard revealed.length > 0 || revealed.location > 0 else { return (hideable, joins, replacements) }
            let shown = IndexSet(integersIn: revealed.location..<NSMaxRange(revealed))
            let replaced = replacements.filter { index, replacement in
                NSIntersectionRange(NSRange(location: index, length: replacement.length), revealed).length == 0
            }
            return (hideable.subtracting(shown), joins.subtracting(shown), replaced)
        }
    }

    static var settings: EditorSettings { .shared }

    /// The reading size: a little larger than the source font, as a book page is read, not scanned.
    static var bodySize: CGFloat { (CGFloat(settings.fontSize) * 1.15).rounded() }

    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        var descriptor = system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor
        if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
        return NSFont(descriptor: descriptor, size: size) ?? system
    }

    static var bodyFont: NSFont { serif(bodySize) }
    static var codeFont: NSFont { settings.font(scale: 0.95) }
    static var smallFont: NSFont { NSFont.systemFont(ofSize: (bodySize * 0.78).rounded()) }

    static func headingFont(level: Int) -> NSFont {
        let scales: [CGFloat] = [1.85, 1.45, 1.22, 1.08, 1.0, 1.0]
        return NSFont.systemFont(ofSize: (bodySize * scales[min(max(level, 1), 6) - 1]).rounded(), weight: level <= 2 ? .bold : .semibold)
    }

    static var bodyParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.32
        return style
    }

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.textColor, .paragraphStyle: bodyParagraph]
    }

    /// Width of the readable column: about 70 characters of the reading font.
    static var columnWidth: CGFloat {
        ("abcdefghijklmnopqrstuvwxyz" as NSString).size(withAttributes: [.font: bodyFont]).width / 26 * 70
    }

    /// Styles `storage` for the book view and returns what may be hidden.
    @discardableResult
    /// `resolve` gives the text a reference is shown with: (role, target) → title, or nil to show
    /// the target itself.
    static func style(_ storage: NSTextStorage, tokens: [MystToken], pageURL: URL? = nil,
                      resolve: ((String, String) -> String?)? = nil) -> Presentation {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        var presentation = Presentation()
        func hide(_ range: NSRange) {
            guard range.length > 0, NSMaxRange(range) <= text.length else { return }
            presentation.hideable.insert(integersIn: range.location..<NSMaxRange(range))
        }
        /// The whole line of `range`, with its newline.
        func hideLines(_ range: NSRange) {
            hide(text.lineRange(for: range))
        }
        func add(_ attributes: [NSAttributedString.Key: Any], _ range: NSRange) {
            guard range.length > 0, NSMaxRange(range) <= text.length else { return }
            storage.addAttributes(attributes, range: range)
        }
        /// Changes the font's traits in `range`, keeping each run's size (emphasis inside a heading).
        func convertFont(_ range: NSRange, bold: Bool = false, italic: Bool = false) {
            guard range.length > 0, NSMaxRange(range) <= text.length else { return }
            storage.enumerateAttribute(.font, in: range) { value, run, _ in
                guard let font = value as? NSFont else { return }
                var traits = font.fontDescriptor.symbolicTraits
                if bold { traits.insert(.bold) }
                if italic { traits.insert(.italic) }
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                storage.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: run)
            }
        }
        /// Shows `text` instead of `range`.
        func replace(_ range: NSRange, with replacement: NSAttributedString) {
            guard range.length > 0, NSMaxRange(range) <= text.length, replacement.length > 0 else { return }
            presentation.replacements[range.location] = BookReplacement(replacement, length: range.length)
            hide(NSRange(location: range.location + 1, length: range.length - 1))
        }
        func delimiterLength(_ range: NSRange, _ characters: Set<unichar>) -> Int {
            var n = 0
            while n < range.length / 2, characters.contains(text.character(at: range.location + n)) { n += 1 }
            return n
        }

        storage.beginEditing()
        storage.setAttributes(bodyAttributes, range: full)

        // Where code and math are, so their newlines are never joined.
        var literalLines = IndexSet()
        var openCodeFence: Int?
        var codePanels: [NSRange] = []

        for token in tokens where NSMaxRange(token.range) <= text.length {
            let range = token.range
            switch token.kind {
            case .frontMatter:
                styleFrontMatter(range, in: text, add: add, hide: hide)
                literalLines.insert(integersIn: range.location..<NSMaxRange(range))
            case .heading(let level):
                let line = text.lineRange(for: range)
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = level <= 2 ? bodySize * 0.9 : bodySize * 0.5
                style.paragraphSpacing = bodySize * 0.25
                style.lineHeightMultiple = 1.1
                add([.font: headingFont(level: level), .paragraphStyle: style], line)
                // Closing hashes: "## Title ##".
                let lineText = text.substring(with: line) as NSString
                if let closing = closingHashes.firstMatch(in: lineText as String, range: NSRange(location: 0, length: lineText.length)) {
                    hide(NSRange(location: line.location + closing.range.location, length: closing.range(at: 1).length + closing.range(at: 1).location - closing.range.location))
                }
                literalLines.insert(integersIn: line.location..<NSMaxRange(line))
            case .headingMarker:
                // The marker and the spaces after it.
                var end = NSMaxRange(range)
                while end < text.length, text.character(at: end) == 0x20 { end += 1 }
                hide(NSRange(location: range.location, length: end - range.location))
            case .target, .comment:
                hideLines(range)
                literalLines.insert(integersIn: text.lineRange(for: range).location..<NSMaxRange(text.lineRange(for: range)))
            case .strong:
                let n = delimiterLength(range, [0x2A, 0x5F])
                convertFont(range, bold: true)
                hide(NSRange(location: range.location, length: n))
                hide(NSRange(location: NSMaxRange(range) - n, length: n))
            case .emphasis:
                let n = delimiterLength(range, [0x2A, 0x5F])
                convertFont(range, italic: true)
                hide(NSRange(location: range.location, length: n))
                hide(NSRange(location: NSMaxRange(range) - n, length: n))
            case .inlineCode:
                let n = delimiterLength(range, [0x60])
                add([.font: codeFont, .backgroundColor: MystHighlighter.codeBackground], range)
                hide(NSRange(location: range.location, length: n))
                hide(NSRange(location: NSMaxRange(range) - n, length: n))
            case .math:
                if text.character(at: range.location) == 0x24 { // inline $…$
                    add([.font: serif(bodySize, italic: true), .foregroundColor: MystHighlighter.mathColor], range)
                    let n = delimiterLength(range, [0x24])
                    let latex = text.substring(with: NSRange(location: range.location + n, length: range.length - 2 * n))
                    replace(range, with: mathString(latex, size: bodySize))
                } else {
                    let centred = NSMutableParagraphStyle()
                    centred.alignment = .center
                    centred.lineHeightMultiple = 1.25
                    centred.paragraphSpacingBefore = bodySize * 0.3
                    centred.paragraphSpacing = bodySize * 0.3
                    add([.font: serif(bodySize, italic: true), .foregroundColor: MystHighlighter.mathColor, .paragraphStyle: centred], range)
                    literalLines.insert(integersIn: range.location..<NSMaxRange(range))
                    replace(range, with: mathString(text.substring(with: range), size: (bodySize * 1.1).rounded(), centred: true))
                }
            case .mathDelimiter:
                hideLines(range)
            case .codeFence:
                hideLines(range)
                // A plain fenced block becomes a panel, from its opening to its closing fence.
                if let start = openCodeFence {
                    codePanels.append(NSRange(location: start, length: NSMaxRange(range) - start))
                    openCodeFence = nil
                } else {
                    openCodeFence = range.location
                }
            case .code:
                add([.font: codeFont, .paragraphStyle: codeParagraph], range)
                literalLines.insert(integersIn: range.location..<NSMaxRange(range))
            case .directiveFence, .directiveName, .directiveArgument, .directiveOptionKey, .directiveOptionValue:
                // Styled with their block below.
                literalLines.insert(integersIn: text.lineRange(for: range).location..<NSMaxRange(text.lineRange(for: range)))
            case .roleName(let role):
                hide(range)
                styleRole(role, nameRange: range, tokens: tokens, in: text, add: add, hide: hide, replace: replace, resolve: resolve)
            case .roleContent:
                break // styled with its role
            case .linkText:
                add([.foregroundColor: NSColor.linkColor], range)
                if range.location > 0, text.character(at: range.location - 1) == 0x5B { // [
                    hide(NSRange(location: range.location - 1, length: 1))
                }
            case .linkTarget:
                // `](target)`
                let start = max(0, range.location - 2)
                let end = min(text.length, NSMaxRange(range) + 1)
                if text.substring(with: NSRange(location: start, length: 2)) == "](" { hide(NSRange(location: start, length: end - start)) }
            case .url:
                add([.foregroundColor: NSColor.linkColor], range)
                if text.character(at: range.location) == 0x3C { // <url>
                    hide(NSRange(location: range.location, length: 1))
                    hide(NSRange(location: NSMaxRange(range) - 1, length: 1))
                }
            case .listMarker:
                add([.foregroundColor: NSColor.secondaryLabelColor], range)
                literalLines.insert(text.lineRange(for: range).location) // a list item starts a line
            case .blockquoteMarker:
                hide(range)
                let style = NSMutableParagraphStyle()
                style.headIndent = 22
                style.firstLineHeadIndent = 22
                style.lineHeightMultiple = 1.32
                add([.paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor], text.lineRange(for: range))
                convertFont(text.lineRange(for: range), italic: true)
            case .substitution, .footnote:
                add([.foregroundColor: MystHighlighter.accent], range)
            }
        }
        let blocks = DirectiveBlocks.all(in: storage.string).sorted { $0.range.location < $1.range.location }
        var boxes: [BookBox] = codePanels.map { BookBox(range: $0, kind: .panel, depth: 0) }
        for block in blocks {
            let depth = blocks.filter { $0.range != block.range && NSLocationInRange(block.range.location, $0.range) }.count
            if let box = styleDirective(block, depth: depth, in: text, storage: storage, pageURL: pageURL, hide: hide, hideLines: hideLines) {
                boxes.append(box)
            }
            literalLines.insert(integersIn: text.lineRange(for: block.openingLine).location..<NSMaxRange(text.lineRange(for: block.openingLine)))
        }
        // Code panels inside a box are indented with it.
        for i in boxes.indices where boxes[i].kind == .panel {
            boxes[i].depth = boxes.filter { $0.kind != .panel && NSLocationInRange(boxes[i].range.location, $0.range) }.map { $0.depth + 1 }.max() ?? 0
            indent(boxes[i].range, depth: boxes[i].depth, in: storage)
        }
        presentation.boxes = boxes
        storage.endEditing()

        // Newlines inside a paragraph of prose are shown as spaces; not after a hard break
        // (two spaces or a backslash at the end of the line).
        var lineStart = 0
        while lineStart < text.length {
            let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let end = NSMaxRange(line)
            guard end < text.length else { break }
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            let newline = end - 1
            let content = text.substring(with: line)
            if text.character(at: newline) == 0x0A,
               !isBlank(line, in: text), !isBlank(next, in: text),
               !literalLines.contains(line.location), !literalLines.contains(next.location), !literalLines.contains(newline),
               !presentation.hideable.contains(newline),
               !content.hasSuffix("  \n"), !content.hasSuffix("\\\n"),
               !startsBlock(next, in: text) {
                presentation.joins.insert(newline)
            }
            lineStart = end
        }
        return presentation
    }

    static var codeParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.15
        return style
    }

    /// How far the text of a box is indented per level of nesting.
    static let boxInset: CGFloat = 16

    /// Indents every paragraph in `range` into a box `depth` levels deep, keeping the rest of its style.
    static func indent(_ range: NSRange, depth: Int, in storage: NSTextStorage) {
        let inset = boxInset * CGFloat(depth + 1) + 4
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
            let style = ((value as? NSParagraphStyle) ?? bodyParagraph).mutableCopy() as! NSMutableParagraphStyle
            style.headIndent = max(style.headIndent, inset)
            style.firstLineHeadIndent = max(style.firstLineHeadIndent, inset)
            style.tailIndent = -inset
            storage.addAttribute(.paragraphStyle, value: style, range: run)
        }
    }

    /// Changes the paragraph style of the lines in `range`.
    static func changeParagraphs(_ range: NSRange, in storage: NSTextStorage, _ change: (NSMutableParagraphStyle) -> Void) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
            let style = ((value as? NSParagraphStyle) ?? bodyParagraph).mutableCopy() as! NSMutableParagraphStyle
            change(style)
            storage.addAttribute(.paragraphStyle, value: style, range: run)
        }
    }

    static func smallCaps(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [
            [NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType, NSFontDescriptor.FeatureKey.selectorIdentifier: kLowerCaseSmallCapsSelector],
        ]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// A directive as the book shows it: the fence, name and options hidden; admonitions and most
    /// others in a box with their title, code in a panel, figures with their image.
    private static func styleDirective(_ block: DirectiveBlock, depth: Int, in text: NSString, storage: NSTextStorage, pageURL: URL?,
                                       hide: (NSRange) -> Void, hideLines: (NSRange) -> Void) -> BookBox? {
        let opening = text.lineRange(for: block.openingLine)
        for option in block.options { hide(option.line) }
        // The closing fence, when there is one.
        let lastLine = text.lineRange(for: NSRange(location: max(block.range.location, NSMaxRange(block.range) - 1), length: 0))
        let closed = lastLine.location > opening.location
            && text.substring(with: lastLine).trimmingCharacters(in: .whitespacesAndNewlines) == block.fence
        if closed { hide(lastLine) }
        let bodyStart = block.options.last.map { NSMaxRange($0.line) } ?? NSMaxRange(opening)
        let body = NSRange(location: bodyStart, length: max(0, (closed ? lastLine.location : NSMaxRange(block.range)) - bodyStart))
        let name = block.name

        if MystDirectives.code.contains(name) {
            hide(opening)
            return BookBox(range: block.range, kind: .panel, depth: depth)
        }
        if MystDirectives.math.contains(name) {
            hide(opening)
            return nil
        }
        if name == "figure" || name == "image" {
            hide(opening)
            let image = pageURL.flatMap { BookImages.image(block.argument, page: $0) }
            let size = BookImages.displaySize(of: image, width: block.option("width")?.value)
            // The space for the image is reserved by the layout manager above the figure's first line.
            changeParagraphs(opening, in: storage) { $0.alignment = .center }
            if body.length > 0 {
                changeParagraphs(body, in: storage) { $0.alignment = .center }
                storage.addAttributes([.font: serif((bodySize * 0.9).rounded(), italic: true), .foregroundColor: NSColor.secondaryLabelColor], range: body)
            }
            indent(block.range, depth: depth - 1 < 0 ? -1 : depth - 1, in: storage)
            return BookBox(range: block.range, kind: .figure(image, size, missing: image == nil ? block.argument : nil), depth: depth)
        }

        // A box with a title: the argument, else the directive's name in small capitals.
        let line = text.substring(with: block.openingLine) as NSString
        let close = line.range(of: "}")
        guard close.location != NSNotFound else { return nil }
        let color = MystHighlighter.admonitionColor(name) ?? (MystDirectives.admonitions.contains(name) ? MystHighlighter.accent : NSColor.systemGray)
        let titleFont = NSFont.systemFont(ofSize: bodySize * 0.95, weight: .semibold)
        if block.argument.isEmpty {
            let open = line.range(of: "{")
            hide(NSRange(location: block.openingLine.location, length: open.location + 1))
            hide(NSRange(location: block.openingLine.location + close.location, length: 1))
            let nameRange = NSRange(location: block.openingLine.location + open.location + 1, length: close.location - open.location - 1)
            storage.addAttributes([.font: smallCaps(titleFont), .foregroundColor: color], range: nameRange)
        } else {
            var start = close.location + 1
            while start < line.length, line.character(at: start) == 0x20 { start += 1 }
            hide(NSRange(location: block.openingLine.location, length: start))
            storage.addAttributes([.font: titleFont, .foregroundColor: NSColor.textColor],
                                  range: NSRange(location: block.openingLine.location + start, length: line.length - start))
        }
        changeParagraphs(opening, in: storage) { $0.paragraphSpacingBefore = 10; $0.paragraphSpacing = 4 }
        if body.length > 0 {
            let lastBody = text.lineRange(for: NSRange(location: max(body.location, NSMaxRange(body) - 1), length: 0))
            changeParagraphs(lastBody, in: storage) { $0.paragraphSpacing = 10 }
        }
        indent(block.range, depth: depth, in: storage)
        return BookBox(range: block.range, kind: .callout(color), depth: depth)
    }

    private static let closingHashes = try! NSRegularExpression(pattern: #"[ \t]+(#+)[ \t]*(?=\n|$)"#)

    private static func isBlank(_ line: NSRange, in text: NSString) -> Bool {
        text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Lines that start a block of their own: list items, quotes, headings, fences, tables, labels.
    private static func startsBlock(_ line: NSRange, in text: NSString) -> Bool {
        let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || trimmed.hasPrefix(">")
            || trimmed.hasPrefix("#") || trimmed.hasPrefix("```") || trimmed.hasPrefix(":::") || trimmed.hasPrefix("|")
            || trimmed.hasPrefix("$$") || trimmed.hasPrefix(":") || trimmed.hasPrefix("(") || trimmed.hasPrefix("%") {
            return true
        }
        // "1. " and "1) "
        let digits = trimmed.prefix { $0.isNumber }
        return !digits.isEmpty && (trimmed.dropFirst(digits.count).hasPrefix(". ") || trimmed.dropFirst(digits.count).hasPrefix(") "))
    }

    /// Front matter is hidden except its title, which is shown as the page title.
    private static func styleFrontMatter(_ range: NSRange, in text: NSString, add: ([NSAttributedString.Key: Any], NSRange) -> Void,
                                         hide: (NSRange) -> Void) {
        let block = text.substring(with: range) as NSString
        let regex = try! NSRegularExpression(pattern: #"^title:[ \t]*(['"]?)(.+?)\1[ \t]*$"#, options: .anchorsMatchLines)
        guard let match = regex.firstMatch(in: block as String, range: NSRange(location: 0, length: block.length)) else {
            hide(text.lineRange(for: range))
            return
        }
        let title = NSRange(location: range.location + match.range(at: 2).location, length: match.range(at: 2).length)
        let line = text.lineRange(for: title)
        let blockEnd = NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0)))
        // Everything before the title's text, then everything after it but its newline.
        hide(NSRange(location: range.location, length: title.location - range.location))
        let afterTitle = NSMaxRange(title)
        let titleNewline = NSMaxRange(line) - 1
        hide(NSRange(location: afterTitle, length: max(0, titleNewline - afterTitle)))
        hide(NSRange(location: titleNewline + 1, length: max(0, blockEnd - titleNewline - 1)))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = bodySize * 0.6
        style.lineHeightMultiple = 1.1
        add([.font: NSFont.systemFont(ofSize: (bodySize * 2.1).rounded(), weight: .bold), .foregroundColor: NSColor.textColor, .paragraphStyle: style], line)
    }

    /// `{name}` is hidden; its content is shown as the book shows it.
    private static func styleRole(_ role: String, nameRange: NSRange, tokens: [MystToken], in text: NSString,
                                  add: ([NSAttributedString.Key: Any], NSRange) -> Void, hide: (NSRange) -> Void,
                                  replace: (NSRange, NSAttributedString) -> Void, resolve: ((String, String) -> String?)?) {
        guard NSMaxRange(nameRange) < text.length, text.character(at: NSMaxRange(nameRange)) == 0x60 else { return }
        guard let content = tokens.first(where: { $0.kind == .roleContent && $0.range.location == NSMaxRange(nameRange) })?.range,
              content.length >= 2 else { return }
        hide(NSRange(location: content.location, length: 1))
        hide(NSRange(location: NSMaxRange(content) - 1, length: 1))
        let inner = NSRange(location: content.location + 1, length: content.length - 2)
        let body = text.substring(with: inner)
        let whole = NSRange(location: nameRange.location, length: NSMaxRange(content) - nameRange.location)
        let link: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.linkColor]
        switch role {
        case "ref", "numref", "eq", "doc", "term", "download":
            add([.foregroundColor: NSColor.linkColor], inner)
            // `Text <label>` shows just the text.
            if body.hasSuffix(">"), let open = body.range(of: " <", options: .backwards) {
                let offset = (body[..<open.lowerBound] as Substring).utf16.count
                hide(NSRange(location: inner.location + offset, length: inner.length - offset))
            } else if let title = resolve?(role, body) {
                replace(whole, NSAttributedString(string: title, attributes: link))
            }
        case let name where MystCatalog.citationRoles.contains(name):
            add([.foregroundColor: NSColor.linkColor], inner)
            if let shown = resolve?(name, body) { replace(whole, NSAttributedString(string: shown, attributes: link)) }
        case "sub", "subscript":
            add([.font: serif((bodySize * 0.75).rounded()), .baselineOffset: -bodySize * 0.2], inner)
        case "sup", "superscript":
            add([.font: serif((bodySize * 0.75).rounded()), .baselineOffset: bodySize * 0.35], inner)
        case "u", "underline":
            add([.underlineStyle: NSUnderlineStyle.single.rawValue], inner)
        case "del", "strike":
            add([.strikethroughStyle: NSUnderlineStyle.single.rawValue], inner)
        case "kbd":
            add([.font: codeFont, .backgroundColor: MystHighlighter.codeBackground], inner)
        case "math":
            add([.font: serif(bodySize, italic: true), .foregroundColor: MystHighlighter.mathColor], inner)
            replace(whole, mathString(body, size: bodySize))
        default:
            add([.foregroundColor: MystHighlighter.accent], inner)
        }
    }

    /// LaTeX as styled text (`MathText`): variables in italics, scripts smaller and shifted.
    static func mathString(_ latex: String, size: CGFloat, centred: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let color = NSColor.textColor
        for run in MathText.runs(latex) {
            let runSize = (size * pow(0.72, CGFloat(min(run.level, 3)))).rounded()
            let font: NSFont
            switch run.style {
            case .italic: font = serif(runSize, italic: true)
            case .upright: font = serif(runSize)
            case .bold: font = serif(runSize, weight: .bold)
            }
            let offset = run.shift > 0 ? CGFloat(run.shift) * size * 0.34 : CGFloat(run.shift) * size * 0.2
            result.append(NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: color, .baselineOffset: offset]))
        }
        if result.length == 0 { result.append(NSAttributedString(string: " ", attributes: [.font: serif(size)])) }
        if centred {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineSpacing = size * 0.3
            result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    /// The text the cursor's paragraphs cover: shown with their markup.
    static func revealedRange(for selection: NSRange, in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let start = MystTextEditor.Coordinator.paragraphRange(at: selection.location, in: text)
        let end = MystTextEditor.Coordinator.paragraphRange(at: NSMaxRange(selection), in: text)
        return NSUnionRange(start, end)
    }
}

/// Text the book view shows instead of `length` characters of the source: rendered math, a
/// reference's title.
struct BookReplacement: Equatable {
    var text: NSAttributedString
    var length: Int
    var size: CGSize
    var isMultiline: Bool

    init(_ text: NSAttributedString, length: Int) {
        self.text = text
        self.length = length
        let bounds = text.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        isMultiline = text.string.contains("\n")
    }
}

/// Something the book view draws behind the text of a block.
struct BookBox: Equatable {
    enum Kind: Equatable {
        /// An admonition or another directive: a tinted box with a bar in `color`.
        case callout(NSColor)
        /// Code: a plain panel.
        case panel
        /// A figure: its image above the caption (`missing` names a file that was not found).
        case figure(NSImage?, CGSize, missing: String?)

        var isFigure: Bool {
            if case .figure = self { return true }
            return false
        }
    }

    var range: NSRange
    var kind: Kind
    /// How many boxes it sits in.
    var depth: Int
}

/// Images of figures in the book view, read once per file and change date.
@MainActor
enum BookImages {
    private static var cache: [String: (date: Date, image: NSImage)] = [:]

    /// The image `path` refers to from the page at `page`; `name.*` picks SVG, PNG, JPEG, then PDF.
    static func image(_ path: String, page: URL) -> NSImage? {
        guard !path.isEmpty, !path.hasPrefix("http") else { return nil }
        let folder = path.hasPrefix("/") ? nil : page.deletingLastPathComponent()
        var url = folder.map { $0.appendingPathComponent(path) } ?? URL(fileURLWithPath: path)
        if url.lastPathComponent.hasSuffix(".*") {
            let stem = url.deletingPathExtension()
            guard let found = ["svg", "png", "jpg", "jpeg", "gif", "webp", "pdf"].map({ stem.appendingPathExtension($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            url = found
        }
        let key = url.standardizedFileURL.path
        guard let date = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date else { return nil }
        if let cached = cache[key], cached.date == date { return cached.image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = (date, image)
        return image
    }

    /// The size a figure is shown at: its `:width:` (percent of the column or pixels), else its own
    /// width up to the column; at most 460 points high.
    static func displaySize(of image: NSImage?, width option: String?) -> CGSize {
        let column = BookStyler.columnWidth
        guard let image, image.size.width > 0, image.size.height > 0 else { return CGSize(width: min(column, 360), height: 56) }
        var width = min(image.size.width, column)
        if let option = option?.trimmingCharacters(in: .whitespaces) {
            if option.hasSuffix("%"), let percent = Double(option.dropLast()) {
                width = column * CGFloat(percent) / 100
            } else if let pixels = Double(option.replacingOccurrences(of: "px", with: "")) {
                width = min(CGFloat(pixels), column)
            }
        }
        var size = CGSize(width: width, height: width * image.size.height / image.size.width)
        if size.height > 460 { size = CGSize(width: size.width * 460 / size.height, height: 460) }
        return size
    }
}
