// Scribe/UI/Notes/WebEditorBridge.swift
//
// Native-side types for the CodeMirror editor bridge (see WebMarkdownEditor):
//
// - `WebEditorCommand`: a command the native side sends into the editor via
//   `window.scribeCommand(name, arg)` — find / replace / findNext /
//   findPrevious, folding, scrollToLine. Names must match the JS registry
//   (editor-web/src/bridge.js and the modules that register commands).
// - `WebEditorCommandCenter`: routes a command to the right live editor (the
//   one holding keyboard focus in the key window, else the most recent editor
//   in that window). Menu items call e.g.
//       WebEditorCommandCenter.shared.send(.find)
//       WebEditorCommandCenter.shared.send(named: "findNext")
// - `EditorOutlineHeading` / `WebEditorModel`: the heading outline JS posts on
//   change, kept on an observable model so UI (a table of contents) can show it
//   and jump with `scrollToLine`.
// - `EditorCompletionData`: note titles + tags pushed for `[[` / `#` completion.

import AppKit
import Foundation
import Observation

// MARK: - Commands

/// A command for the web editor's `window.scribeCommand` dispatcher.
struct WebEditorCommand: Sendable, Equatable {
    /// JS command name (see editor-web/src/bridge.js).
    let name: String
    /// Argument as a JS/JSON literal (`null` when none).
    let argumentJSON: String

    init(name: String, argumentJSON: String) {
        self.name = name
        self.argumentJSON = argumentJSON
    }

    /// A command with no argument.
    static func named(_ name: String) -> WebEditorCommand {
        WebEditorCommand(name: name, argumentJSON: "null")
    }

    static let find = WebEditorCommand.named("find")
    static let replace = WebEditorCommand.named("replace")
    static let findNext = WebEditorCommand.named("findNext")
    static let findPrevious = WebEditorCommand.named("findPrevious")
    static let selectAllMatches = WebEditorCommand.named("selectAllMatches")
    static let replaceAll = WebEditorCommand.named("replaceAll")
    static let closeFind = WebEditorCommand.named("closeFind")
    static let fold = WebEditorCommand.named("fold")
    static let unfold = WebEditorCommand.named("unfold")
    static let toggleFold = WebEditorCommand.named("toggleFold")
    static let foldAll = WebEditorCommand.named("foldAll")
    static let unfoldAll = WebEditorCommand.named("unfoldAll")

    /// Opens the find panel prefilled with `query`.
    static func findPrefilled(_ query: String) -> WebEditorCommand {
        WebEditorCommand(name: "find", argumentJSON: WebEditorJS.stringLiteral(query))
    }

    /// Moves the caret to (and scrolls to) a 1-based line.
    static func scrollToLine(_ line: Int) -> WebEditorCommand {
        WebEditorCommand(name: "scrollToLine", argumentJSON: String(max(1, line)))
    }

    /// Maps a standard Edit › Find menu item (`performTextFinderAction:`,
    /// whose tag is an `NSTextFinder.Action` raw value) to an editor command,
    /// so the system Find menu drives the CodeMirror search panel. nil for
    /// actions the editor doesn't map (they fall through to WebKit).
    static func forTextFinderAction(tag: Int) -> WebEditorCommand? {
        switch tag {
        case 1: return .find              // showFindInterface
        case 2: return .findNext          // nextMatch
        case 3: return .findPrevious      // previousMatch
        case 4: return .replaceAll        // replaceAll
        case 7: return .find              // setSearchString (panel seeds from the selection)
        case 9: return .selectAllMatches  // selectAll
        case 11: return .closeFind        // hideFindInterface
        case 12: return .replace          // showReplaceInterface
        default: return nil
        }
    }

    /// The JavaScript that runs this command (guarded so an older bundle
    /// without the dispatcher is a no-op).
    var javaScript: String {
        "window.scribeCommand && window.scribeCommand(\(WebEditorJS.stringLiteral(name)), \(argumentJSON));"
    }
}

/// JS literal helpers shared by the bridge types.
enum WebEditorJS {
    /// Escapes a string into a JS string literal (including quotes) via
    /// JSONSerialization, so control characters and U+2028/2029 are safe.
    static func stringLiteral(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let array = String(data: data, encoding: .utf8) {
            let start = array.index(after: array.startIndex)
            let end = array.index(before: array.endIndex)
            return String(array[start..<end])
        }
        return "\"\""
    }

    /// Serializes a JSON-compatible object (dictionaries / arrays of strings,
    /// numbers, bools) to a JS literal; `fallback` when it can't.
    static func jsonLiteral(_ object: Any, fallback: String) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: data, encoding: .utf8) else { return fallback }
        return string
    }
}

// MARK: - Outline

/// One heading of the open note, as reported by the editor.
struct EditorOutlineHeading: Sendable, Equatable, Identifiable, Hashable {
    /// 1...6
    let level: Int
    let text: String
    /// 1-based line in the markdown body.
    let line: Int

    var id: Int { line }

    /// Parses the `headings` array of an `{type:"outline"}` message. Entries
    /// with a missing / out-of-range level or line are skipped.
    static func parseList(_ raw: Any?) -> [EditorOutlineHeading] {
        guard let items = raw as? [Any] else { return [] }
        var result: [EditorOutlineHeading] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard let dict = item as? [String: Any],
                  let level = intValue(dict["level"]), (1...6).contains(level),
                  let line = intValue(dict["line"]), line >= 1 else { continue }
            let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.append(EditorOutlineHeading(level: level, text: text, line: line))
        }
        return result
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double, double.isFinite { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

/// Note titles and tags offered by `[[` and `#` completion in the editor.
struct EditorCompletionData: Sendable, Equatable {
    var titles: [String]
    var tags: [String]

    init(titles: [String], tags: [String]) {
        self.titles = titles
        self.tags = tags
    }

    /// `{titles:[…], tags:[…]}` as a JS literal.
    var javaScriptLiteral: String {
        WebEditorJS.jsonLiteral(["titles": titles, "tags": tags], fallback: "{\"titles\":[],\"tags\":[]}")
    }
}

/// Observable per-editor state for native UI: the live heading outline, plus
/// a handle to send commands to this specific editor.
@MainActor
@Observable
final class WebEditorModel {
    /// Headings of the open note, updated (debounced) as the user types.
    var outline: [EditorOutlineHeading] = []

    @ObservationIgnored
    weak var coordinator: WebMarkdownEditor.Coordinator?

    init() {}

    /// Sends a command to this editor. Returns false when it isn't loaded.
    @discardableResult
    func perform(_ command: WebEditorCommand) -> Bool {
        guard let coordinator else { return false }
        return coordinator.run(command)
    }

    /// Jumps the editor to a heading's line.
    func scrollTo(_ heading: EditorOutlineHeading) {
        perform(.scrollToLine(heading.line))
    }
}

// MARK: - Routing

/// Routes commands from menus to the active web editor.
@MainActor
final class WebEditorCommandCenter {
    static let shared = WebEditorCommandCenter()

    private final class WeakCoordinator {
        weak var value: WebMarkdownEditor.Coordinator?
        init(_ value: WebMarkdownEditor.Coordinator) { self.value = value }
    }

    /// Registration order = creation order (most recent last).
    private var editors: [WeakCoordinator] = []

    init() {}

    func register(_ coordinator: WebMarkdownEditor.Coordinator) {
        editors.removeAll { $0.value == nil || $0.value === coordinator }
        editors.append(WeakCoordinator(coordinator))
    }

    func unregister(_ coordinator: WebMarkdownEditor.Coordinator) {
        editors.removeAll { $0.value == nil || $0.value === coordinator }
    }

    /// Whether any editor would receive a command right now (for menu
    /// validation).
    var hasTarget: Bool { target() != nil }

    /// Sends `command` to the active editor. Returns false when no editor is
    /// in the key (or main) window.
    @discardableResult
    func send(_ command: WebEditorCommand) -> Bool {
        guard let target = target() else { return false }
        return target.run(command)
    }

    /// String-named convenience for callers that only know the JS name.
    @discardableResult
    func send(named name: String) -> Bool {
        send(.named(name))
    }

    private func target() -> WebMarkdownEditor.Coordinator? {
        editors.removeAll { $0.value == nil }
        // Checked first so a process without an NSApplication (unit tests)
        // never touches NSApp.
        guard !editors.isEmpty,
              let app = NSApp,
              let window = app.keyWindow ?? app.mainWindow else { return nil }
        let inWindow = editors.compactMap(\.value).filter { $0.webView?.window === window }
        if let focused = inWindow.first(where: { $0.isFirstResponder(in: window) }) {
            return focused
        }
        return inWindow.last
    }
}
