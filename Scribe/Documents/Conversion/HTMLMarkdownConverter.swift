// Scribe/Documents/Conversion/HTMLMarkdownConverter.swift
//
// A small, tolerant HTML → Markdown converter shared by the Evernote (ENML)
// and Apple Notes (exported HTML) importers. Pure Swift — its own tokenizer
// and tree builder, no WebKit / NSAttributedString — so it runs off the main
// actor and is unit tested with fixture strings (HTMLMarkdownConverterTests).
//
// It aims for readable Markdown, not a lossless round-trip: structure
// (headings, paragraphs, lists, checklists, quotes, code, tables, links,
// images) survives; presentational styling mostly doesn't.

import Foundation

// MARK: - Tree

/// A parsed HTML node.
indirect enum HTMLNode: Equatable {
    case text(String)
    case element(name: String, attributes: [String: String], children: [HTMLNode])

    var name: String? {
        if case .element(let name, _, _) = self { return name }
        return nil
    }

    var attributes: [String: String] {
        if case .element(_, let attributes, _) = self { return attributes }
        return [:]
    }

    var children: [HTMLNode] {
        if case .element(_, _, let children) = self { return children }
        return []
    }
}

// MARK: - Tokenizer + tree builder

enum HTMLTreeParser {

    /// Elements that never have content.
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr", "en-media", "en-todo",
    ]

    /// Elements whose content is raw text (skipped up to the closing tag).
    static let rawTextElements: Set<String> = ["script", "style"]

    private enum Token {
        case text(String)
        case start(name: String, attributes: [String: String], selfClosing: Bool)
        case end(name: String)
    }

    /// Parses `html` into a synthetic root element named `#root`. Unclosed
    /// tags are closed at the end; stray end tags are ignored.
    static func parse(_ html: String) -> HTMLNode {
        let tokens = tokenize(Array(html))
        var stack: [(name: String, attributes: [String: String], children: [HTMLNode])] = [
            (name: "#root", attributes: [:], children: []),
        ]
        func closeTop() {
            let top = stack.removeLast()
            let node = HTMLNode.element(name: top.name, attributes: top.attributes, children: top.children)
            stack[stack.count - 1].children.append(node)
        }
        for token in tokens {
            switch token {
            case .text(let text):
                stack[stack.count - 1].children.append(.text(text))
            case .start(let name, let attributes, let selfClosing):
                if selfClosing || voidElements.contains(name) {
                    stack[stack.count - 1].children.append(.element(name: name, attributes: attributes, children: []))
                } else {
                    // An open <p> / <li> is implicitly closed by a sibling.
                    if name == "li" || name == "p" || name == "tr" || name == "td" || name == "th",
                       let openName = stack.last?.name, openName == name {
                        closeTop()
                    }
                    stack.append((name: name, attributes: attributes, children: []))
                }
            case .end(let name):
                guard stack.count > 1,
                      let index = stack.lastIndex(where: { $0.name == name }), index > 0 else { continue }
                while stack.count > index { closeTop() }
            }
        }
        while stack.count > 1 { closeTop() }
        return .element(name: "#root", attributes: [:], children: stack[0].children)
    }

    private static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var i = 0
        let n = chars.count

        func flushText() {
            if !text.isEmpty {
                tokens.append(.text(HTMLEntities.decode(text)))
                text = ""
            }
        }
        func hasPrefix(_ prefix: String, at index: Int) -> Bool {
            var j = index
            for c in prefix {
                guard j < n, chars[j].lowercased() == c.lowercased() else { return false }
                j += 1
            }
            return true
        }
        func find(_ needle: String, from index: Int) -> Int? {
            var j = index
            while j < n {
                if hasPrefix(needle, at: j) { return j }
                j += 1
            }
            return nil
        }

        while i < n {
            let c = chars[i]
            guard c == "<" else {
                text.append(c)
                i += 1
                continue
            }
            if hasPrefix("<!--", at: i) {
                flushText()
                i = (find("-->", from: i + 4).map { $0 + 3 }) ?? n
                continue
            }
            if hasPrefix("<![CDATA[", at: i) {
                flushText()
                let start = i + 9
                let end = find("]]>", from: start) ?? n
                tokens.append(.text(String(chars[start..<end])))
                i = min(n, end + 3)
                continue
            }
            if hasPrefix("<!", at: i) || hasPrefix("<?", at: i) {
                flushText()
                i = (find(">", from: i + 2).map { $0 + 1 }) ?? n
                continue
            }
            if i + 1 < n, chars[i + 1] == "/" {
                // End tag.
                var j = i + 2
                var name = ""
                while j < n, chars[j] != ">" {
                    if !chars[j].isWhitespace { name.append(chars[j]) }
                    j += 1
                }
                flushText()
                tokens.append(.end(name: name.lowercased()))
                i = min(n, j + 1)
                continue
            }
            guard i + 1 < n, chars[i + 1].isLetter else {
                text.append(c)
                i += 1
                continue
            }
            // Start tag.
            var j = i + 1
            var name = ""
            while j < n, !chars[j].isWhitespace, chars[j] != ">", chars[j] != "/" {
                name.append(chars[j])
                j += 1
            }
            var attributes: [String: String] = [:]
            var selfClosing = false
            while j < n {
                while j < n, chars[j].isWhitespace { j += 1 }
                guard j < n else { break }
                if chars[j] == ">" { j += 1; break }
                if chars[j] == "/" {
                    selfClosing = true
                    j += 1
                    continue
                }
                var attrName = ""
                while j < n, !chars[j].isWhitespace, chars[j] != "=", chars[j] != ">", chars[j] != "/" {
                    attrName.append(chars[j])
                    j += 1
                }
                while j < n, chars[j].isWhitespace { j += 1 }
                var value = ""
                if j < n, chars[j] == "=" {
                    j += 1
                    while j < n, chars[j].isWhitespace { j += 1 }
                    if j < n, chars[j] == "\"" || chars[j] == "'" {
                        let quote = chars[j]
                        j += 1
                        while j < n, chars[j] != quote {
                            value.append(chars[j])
                            j += 1
                        }
                        j += 1
                    } else {
                        while j < n, !chars[j].isWhitespace, chars[j] != ">" {
                            value.append(chars[j])
                            j += 1
                        }
                    }
                }
                if !attrName.isEmpty {
                    attributes[attrName.lowercased()] = HTMLEntities.decode(value)
                }
                if attrName.isEmpty, j < n, chars[j] != ">" { j += 1 }
            }
            flushText()
            let lowered = name.lowercased()
            tokens.append(.start(name: lowered, attributes: attributes, selfClosing: selfClosing))
            i = j
            if rawTextElements.contains(lowered), !selfClosing {
                // Skip the raw content and its end tag entirely.
                if let end = find("</\(lowered)", from: i) {
                    i = (find(">", from: end).map { $0 + 1 }) ?? n
                } else {
                    i = n
                }
                tokens.append(.end(name: lowered))
            }
        }
        flushText()
        return tokens
    }
}

// MARK: - Entities

enum HTMLEntities {

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "copy": "\u{00A9}", "reg": "\u{00AE}",
        "trade": "\u{2122}", "times": "\u{00D7}", "deg": "\u{00B0}", "euro": "\u{20AC}",
        "pound": "\u{00A3}", "laquo": "\u{00AB}", "raquo": "\u{00BB}", "shy": "",
    ]

    /// Decodes named and numeric character references; unknown ones are kept.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            guard c == "&", let semi = text[index...].prefix(12).firstIndex(of: ";") else {
                out.append(c)
                index = text.index(after: index)
                continue
            }
            let entity = String(text[text.index(after: index)..<semi])
            if let decoded = decodeEntity(entity) {
                out += decoded
                index = text.index(after: semi)
            } else {
                out.append(c)
                index = text.index(after: index)
            }
        }
        return out
    }

    private static func decodeEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#") {
            let digits = entity.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return value == 0xA0 ? " " : String(Character(scalar))
        }
        return named[entity.lowercased()]
    }
}

// MARK: - Converter

/// Hooks the importers use to map embedded resources.
struct HTMLMarkdownOptions {
    /// `<img src alt>` → the Markdown destination to embed, or nil to drop
    /// the image. Default: keep `src` unless it's a `data:` URL.
    var resolveImage: (_ src: String, _ alt: String) -> String? = { src, _ in
        src.lowercased().hasPrefix("data:") ? nil : src
    }
    /// Evernote `<en-media>` (attributes include `hash` and `type`) → the
    /// complete Markdown to insert (`![](…)` or `[name](…)`), or nil to drop.
    var resolveMedia: (_ attributes: [String: String]) -> String? = { _ in nil }
    /// Rewrites a link `href` (e.g. to a wiki link target).
    var resolveLink: (_ href: String) -> String = { $0 }

    init() {}
}

enum HTMLMarkdownConverter {

    /// Converts an HTML (or ENML) document or fragment to Markdown.
    static func markdown(fromHTML html: String, options: HTMLMarkdownOptions = HTMLMarkdownOptions()) -> String {
        let root = HTMLTreeParser.parse(html)
        var renderer = HTMLMarkdownRenderer(options: options)
        renderer.renderChildren(of: bodyNode(in: root))
        return HTMLMarkdownRenderer.cleanUp(renderer.out)
    }

    /// The `<body>` / `<en-note>` element if present, else the root.
    static func bodyNode(in root: HTMLNode) -> HTMLNode {
        if let found = firstElement(named: ["body", "en-note"], in: root) { return found }
        return root
    }

    /// Text of the first `<title>` element, if any.
    static func documentTitle(inHTML html: String) -> String? {
        let root = HTMLTreeParser.parse(html)
        guard let title = firstElement(named: ["title"], in: root) else { return nil }
        let text = HTMLMarkdownRenderer.plainText(of: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func firstElement(named names: Set<String>, in node: HTMLNode) -> HTMLNode? {
        for child in node.children {
            if let name = child.name, names.contains(name) { return child }
            if let found = firstElement(named: names, in: child) { return found }
        }
        return nil
    }
}

/// Renders an `HTMLNode` tree into Markdown. A value type: nested blocks
/// (list items, quotes) render into a fresh renderer and are re-indented.
struct HTMLMarkdownRenderer {
    let options: HTMLMarkdownOptions
    var out = ""
    /// Rendering the content of a list item (en-todo then emits `[ ] `
    /// instead of starting a new `- [ ] ` item).
    var inListItem = false

    init(options: HTMLMarkdownOptions, inListItem: Bool = false) {
        self.options = options
        self.inListItem = inListItem
    }

    static let skippedElements: Set<String> = ["head", "title", "script", "style", "meta", "link", "noscript"]
    static let paragraphElements: Set<String> = ["p", "address", "figure", "figcaption", "center"]
    static let lineElements: Set<String> = [
        "div", "section", "article", "header", "footer", "main", "nav", "aside",
        "body", "html", "en-note", "dl", "dt", "dd", "form", "fieldset",
    ]

    // MARK: Output helpers

    private var atLineStart: Bool {
        out.isEmpty || out.hasSuffix("\n")
    }

    /// Ensures the output ends with at least `count` newlines (no-op on
    /// empty output, so documents never start with blank lines).
    mutating func ensureNewlines(_ count: Int) {
        guard !out.isEmpty else { return }
        // Trailing spaces before a line break are noise.
        while out.hasSuffix(" ") { out.removeLast() }
        var existing = 0
        for c in out.reversed() {
            if c == "\n" { existing += 1 } else { break }
        }
        if existing < count {
            out += String(repeating: "\n", count: count - existing)
        }
    }

    mutating func appendText(_ raw: String) {
        var text = Self.collapseWhitespace(raw)
        if atLineStart || out.hasSuffix(" ") {
            while text.hasPrefix(" ") { text.removeFirst() }
        }
        guard !text.isEmpty else { return }
        if atLineStart {
            text = Self.escapeLineStart(text)
        }
        out += text
    }

    // MARK: Rendering

    mutating func renderChildren(of node: HTMLNode) {
        for child in node.children { render(child) }
    }

    mutating func render(_ node: HTMLNode) {
        switch node {
        case .text(let text):
            appendText(text)
        case .element(let name, let attributes, let children):
            renderElement(name: name, attributes: attributes, children: children, node: node)
        }
    }

    private mutating func renderElement(name: String, attributes: [String: String], children: [HTMLNode], node: HTMLNode) {
        if Self.skippedElements.contains(name) { return }
        let style = (attributes["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")

        switch name {
        case "br":
            if inListItem {
                out += "\n"
            } else {
                while out.hasSuffix(" ") { out.removeLast() }
                out += "\n"
            }
        case "hr":
            ensureNewlines(2)
            out += "---"
            ensureNewlines(2)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(name.dropFirst())) ?? 1
            let text = inlineMarkdown(of: children).replacingOccurrences(of: "\n", with: " ")
            guard !text.isEmpty else { return }
            ensureNewlines(2)
            out += String(repeating: "#", count: level) + " " + text
            ensureNewlines(2)
        case "strong", "b":
            wrapInline(children, marker: "**")
        case "em", "i", "cite", "var", "dfn":
            wrapInline(children, marker: "*")
        case "s", "strike", "del":
            wrapInline(children, marker: "~~")
        case "code", "kbd", "samp", "tt":
            let text = Self.plainText(of: node).replacingOccurrences(of: "\n", with: " ")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let fence = text.contains("`") ? "``" : "`"
            out += fence + text + fence
        case "a":
            renderLink(attributes: attributes, children: children)
        case "img":
            let src = attributes["src"] ?? ""
            let alt = (attributes["alt"] ?? "").replacingOccurrences(of: "\n", with: " ")
            guard !src.isEmpty, let destination = options.resolveImage(src, alt) else { return }
            out += "![\(Self.escapeBrackets(alt))](\(Self.markdownDestination(destination)))"
        case "en-media":
            if let markdown = options.resolveMedia(attributes) {
                out += markdown
            }
        case "en-todo":
            let checked = (attributes["checked"] ?? "").lowercased() == "true"
            let box = checked ? "[x] " : "[ ] "
            if inListItem && out.trimmingCharacters(in: .whitespaces).isEmpty {
                out += box
            } else {
                if !atLineStart { ensureNewlines(1) }
                out += "- " + box
            }
        case "en-crypt":
            ensureNewlines(1)
            out += "*(Encrypted Evernote content was not imported.)*"
            ensureNewlines(1)
        case "ul", "ol":
            renderList(ordered: name == "ol", attributes: attributes, children: children)
        case "li":
            // An <li> outside a list: render as a bullet.
            renderListItem(children: children, attributes: attributes, marker: "- ", forceTask: nil)
        case "blockquote":
            renderBlockquote(children)
        case "pre":
            renderCodeBlock(Self.plainText(of: node))
        case "table":
            renderTable(node)
        default:
            if style.contains("-en-codeblock:true") {
                renderCodeBlock(Self.plainText(of: node))
            } else if Self.paragraphElements.contains(name) {
                ensureNewlines(2)
                renderChildren(of: node)
                ensureNewlines(2)
            } else if Self.lineElements.contains(name) {
                ensureNewlines(1)
                let before = out.utf8.count
                renderChildren(of: node)
                // An empty <div><br/></div> is Evernote's blank line.
                if out.utf8.count == before || children.isEmpty {
                    ensureNewlines(2)
                } else {
                    ensureNewlines(1)
                }
            } else if name == "span" || name == "font" {
                if style.contains("font-weight:bold") || style.contains("font-weight:700") {
                    wrapInline(children, marker: "**")
                } else if style.contains("font-style:italic") {
                    wrapInline(children, marker: "*")
                } else if style.contains("text-decoration:line-through") {
                    wrapInline(children, marker: "~~")
                } else {
                    renderChildren(of: node)
                }
            } else {
                // Unknown / presentational inline element (u, sup, mark, …).
                renderChildren(of: node)
            }
        }
    }

    // MARK: Inline helpers

    /// Renders `children` on their own and returns the trimmed Markdown.
    private func inlineMarkdown(of children: [HTMLNode]) -> String {
        var sub = HTMLMarkdownRenderer(options: options)
        for child in children { sub.render(child) }
        return HTMLMarkdownRenderer.cleanUp(sub.out)
    }

    private mutating func wrapInline(_ children: [HTMLNode], marker: String) {
        let leadingSpace = Self.startsWithWhitespace(children)
        let trailingSpace = Self.endsWithWhitespace(children)
        let content = inlineMarkdown(of: children)
        guard !content.isEmpty else {
            if leadingSpace || trailingSpace { appendText(" ") }
            return
        }
        if leadingSpace { appendText(" ") }
        let lines = content.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "" : marker + trimmed + marker
        }
        out += lines.joined(separator: "\n")
        if trailingSpace { out += " " }
    }

    private mutating func renderLink(attributes: [String: String], children: [HTMLNode]) {
        let href = (attributes["href"] ?? "").trimmingCharacters(in: .whitespaces)
        let text = inlineMarkdown(of: children).replacingOccurrences(of: "\n", with: " ")
        guard !href.isEmpty, !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:") else {
            appendText(text)
            return
        }
        let target = options.resolveLink(href)
        if target.hasPrefix("[[") {
            out += target
            return
        }
        if Self.startsWithWhitespace(children) { appendText(" ") }
        if text.isEmpty || text == href || text == target {
            out += "<\(target)>"
        } else {
            out += "[\(Self.escapeBrackets(text))](\(Self.markdownDestination(target)))"
        }
        if Self.endsWithWhitespace(children) { out += " " }
    }

    // MARK: Blocks

    private mutating func renderList(ordered: Bool, attributes: [String: String], children: [HTMLNode]) {
        ensureNewlines(1)
        let isChecklist = (attributes["class"] ?? "").lowercased().contains("checklist")
            || (attributes["data-todo"] ?? "").lowercased() == "true"
        var number = Int(attributes["start"] ?? "") ?? 1
        for child in children {
            guard case .element(let name, let itemAttributes, let itemChildren) = child else {
                // Stray text between <li>s.
                if case .text(let text) = child, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    renderListItem(children: [child], attributes: [:], marker: "- ", forceTask: nil)
                }
                continue
            }
            if name == "ul" || name == "ol" {
                // Malformed nesting (<ul><ul>…</ul></ul>): indent it.
                var sub = HTMLMarkdownRenderer(options: options)
                sub.render(child)
                appendIndentedBlock(HTMLMarkdownRenderer.cleanUp(sub.out), firstPrefix: "  ", indent: "  ")
                continue
            }
            guard name == "li" else { continue }
            let marker = ordered ? "\(number). " : "- "
            number += 1
            let checkedAttr = (itemAttributes["data-checked"] ?? itemAttributes["checked"] ?? "").lowercased()
            let classes = (itemAttributes["class"] ?? "").lowercased()
            var task: Bool? = nil
            if isChecklist || !checkedAttr.isEmpty || classes.contains("checked") || classes.contains("unchecked") {
                task = checkedAttr == "true" || (classes.contains("checked") && !classes.contains("unchecked"))
            }
            renderListItem(children: itemChildren, attributes: itemAttributes, marker: marker, forceTask: task)
        }
        // A blank line after a top-level list, so what follows isn't read as
        // a lazy continuation of its last item.
        ensureNewlines(inListItem ? 1 : 2)
    }

    private mutating func renderListItem(children: [HTMLNode], attributes: [String: String], marker: String, forceTask: Bool?) {
        var sub = HTMLMarkdownRenderer(options: options, inListItem: true)
        for child in children { sub.render(child) }
        var content = HTMLMarkdownRenderer.cleanUp(sub.out)
        // (Without `forceTask`, an en-todo inside the item already put its
        // `[ ] ` box at the start of `content`.)
        var prefix = marker
        if let forceTask {
            prefix += forceTask ? "[x] " : "[ ] "
            if content.hasPrefix("[ ] ") || content.hasPrefix("[x] ") {
                content.removeFirst(4)
            }
        }
        ensureNewlines(1)
        appendIndentedBlock(content, firstPrefix: prefix, indent: String(repeating: " ", count: marker.count))
    }

    /// Appends `block` with `firstPrefix` before its first line and
    /// `indent` before every other non-empty line.
    private mutating func appendIndentedBlock(_ block: String, firstPrefix: String, indent: String) {
        let lines = block.components(separatedBy: "\n")
        var rendered: [String] = []
        for (index, line) in lines.enumerated() {
            if index == 0 {
                rendered.append(firstPrefix + line)
            } else {
                rendered.append(line.isEmpty ? "" : indent + line)
            }
        }
        if !atLineStart { ensureNewlines(1) }
        out += rendered.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n")
        ensureNewlines(1)
    }

    private mutating func renderBlockquote(_ children: [HTMLNode]) {
        var sub = HTMLMarkdownRenderer(options: options)
        for child in children { sub.render(child) }
        let content = HTMLMarkdownRenderer.cleanUp(sub.out)
        guard !content.isEmpty else { return }
        ensureNewlines(2)
        out += content.components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
        ensureNewlines(2)
    }

    private mutating func renderCodeBlock(_ raw: String) {
        let code = raw.trimmingCharacters(in: .newlines)
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let fence = code.contains("```") ? "~~~" : "```"
        ensureNewlines(2)
        out += fence + "\n" + code + "\n" + fence
        ensureNewlines(2)
    }

    private mutating func renderTable(_ table: HTMLNode) {
        var rows: [[String]] = []
        collectRows(table, into: &rows)
        rows = rows.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: columns - cells.count)
            return "| " + padded.joined(separator: " | ") + " |"
        }
        ensureNewlines(2)
        var lines = [line(rows[0]), "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"]
        for row in rows.dropFirst() { lines.append(line(row)) }
        out += lines.joined(separator: "\n")
        ensureNewlines(2)
    }

    private func collectRows(_ node: HTMLNode, into rows: inout [[String]]) {
        for child in node.children {
            guard let name = child.name else { continue }
            if name == "tr" {
                var cells: [String] = []
                for cell in child.children where cell.name == "td" || cell.name == "th" {
                    let text = inlineMarkdown(of: cell.children)
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "|", with: "\\|")
                    cells.append(text)
                }
                rows.append(cells)
            } else if name != "table" {
                // thead / tbody / tfoot (a nested table is flattened away).
                collectRows(child, into: &rows)
            }
        }
    }

    // MARK: - Static helpers

    /// Text content of a subtree, with block elements and `<br>` as line
    /// breaks — used for `<pre>` / code blocks and `<title>`.
    static func plainText(of node: HTMLNode) -> String {
        switch node {
        case .text(let text):
            return text
        case .element(let name, _, let children):
            if name == "br" { return "\n" }
            if skippedElements.contains(name) && name != "title" { return "" }
            var parts = ""
            for child in children {
                let isBlock = child.name.map { lineElements.contains($0) || paragraphElements.contains($0) || $0 == "li" } ?? false
                if isBlock, !parts.isEmpty, !parts.hasSuffix("\n") { parts += "\n" }
                parts += plainText(of: child)
                if isBlock, !parts.hasSuffix("\n") { parts += "\n" }
            }
            return parts
        }
    }

    static func collapseWhitespace(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = false
        for c in text {
            if c.isWhitespace || c.isNewline {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(c)
                lastWasSpace = false
            }
        }
        return out
    }

    /// Backslash-escapes text that would otherwise start a Markdown block
    /// (heading, quote, list item) at the beginning of a line.
    static func escapeLineStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if first == ">" { return "\\" + text }
        if first == "#" {
            // Only a heading when the run of #s is followed by a space —
            // a leading #hashtag stays as it is.
            let rest = text.drop(while: { $0 == "#" })
            if rest.isEmpty || rest.first == " " { return "\\" + text }
            return text
        }
        if (first == "-" || first == "+" || first == "*"), text.dropFirst().first == " " {
            return "\\" + text
        }
        // "1. " → "1\. "
        let digits = text.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 9 {
            let rest = text.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return String(digits) + "\\" + String(rest)
            }
        }
        return text
    }

    static func escapeBrackets(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    /// Wraps a destination containing spaces or parentheses in `<…>`.
    static func markdownDestination(_ destination: String) -> String {
        if destination.contains(" ") || destination.contains("(") || destination.contains(")") {
            return "<\(destination)>"
        }
        return destination
    }

    private static func startsWithWhitespace(_ children: [HTMLNode]) -> Bool {
        guard let first = children.first, case .text(let text) = first else { return false }
        return text.first.map { $0.isWhitespace } ?? false
    }

    private static func endsWithWhitespace(_ children: [HTMLNode]) -> Bool {
        guard let last = children.last, case .text(let text) = last else { return false }
        return text.last.map { $0.isWhitespace } ?? false
    }

    /// Final tidy-up: trailing spaces off every line, at most one blank line
    /// in a row (outside fenced code), no leading/trailing blank lines.
    static func cleanUp(_ markdown: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        var inFence = false
        for rawLine in markdown.components(separatedBy: "\n") {
            var line = rawLine
            let trimmedStart = line.trimmingCharacters(in: .whitespaces)
            if trimmedStart.hasPrefix("```") || trimmedStart.hasPrefix("~~~") {
                inFence.toggle()
            }
            if !inFence {
                while line.hasSuffix(" ") { line.removeLast() }
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty && !inFence {
                blankRun += 1
                if blankRun > 1 { continue }
                lines.append("")
            } else {
                blankRun = 0
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
