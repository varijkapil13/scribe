// Scribe/UI/Notes/NoteInspector.swift
import SwiftUI

// MARK: - Statistics (pure)

/// Word / character counts and reading time for a note body. Pure so it can be
/// unit-tested and computed cheaply from the inspector.
struct NoteStatistics: Equatable, Sendable {
    let words: Int
    let characters: Int
    /// Estimated reading time in whole minutes (0 only for an empty note).
    let readingMinutes: Int

    /// Average adult silent-reading speed used for the estimate.
    static let wordsPerMinute = 200

    nonisolated static func compute(body: String) -> NoteStatistics {
        var words = 0
        body.enumerateSubstrings(in: body.startIndex..<body.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        let characters = body.filter { !$0.isNewline }.count
        return NoteStatistics(words: words,
                              characters: characters,
                              readingMinutes: readingMinutes(forWords: words))
    }

    nonisolated static func readingMinutes(forWords words: Int) -> Int {
        guard words > 0 else { return 0 }
        return max(1, (words + wordsPerMinute - 1) / wordsPerMinute)
    }

    /// "1 min", "4 min" — or "—" for an empty note.
    nonisolated static func readingTimeLabel(minutes: Int) -> String {
        minutes <= 0 ? "—" : "\(minutes) min"
    }
}

// MARK: - Inspector modifier

/// Adds the note inspector (`.inspector`) with its toolbar toggle to a note
/// detail, and publishes the open note to the menu bar (`FocusedValues.scribeNote`)
/// so File › Print / Export as PDF, Open in New Window and View › Show
/// Inspector (⌥⌘I) act on it.
struct NoteInspectorModifier: ViewModifier {
    @ObservedObject var vm: NoteDetailViewModel
    let editorModel: WebEditorModel?
    @Binding var isPresented: Bool
    let onNavigate: (String) -> Void

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: $isPresented) {
                NoteInspectorView(vm: vm, editorModel: editorModel, onNavigate: onNavigate)
                    .inspectorColumnWidth(min: 220, ideal: DesignTokens.Notes.inspectorWidth, max: 380)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresented.toggle()
                    } label: {
                        Label(isPresented ? "Hide Inspector" : "Show Inspector",
                              systemImage: "info.circle")
                    }
                    .help(isPresented ? "Hide note info (⌥⌘I)" : "Show note info (⌥⌘I)")
                    .accessibilityLabel(isPresented ? "Hide inspector" : "Show inspector")
                }
            }
            .focusedSceneValue(\.scribeNote, NoteCommandContext(
                noteId: vm.note.id,
                title: vm.note.title,
                isInspectorPresented: $isPresented
            ))
    }
}

// MARK: - Inspector content

/// Note info: properties, backlinks, outline, linked meetings, unlinked
/// mentions, statistics and history.
struct NoteInspectorView: View {
    @ObservedObject var vm: NoteDetailViewModel
    var editorModel: WebEditorModel?
    let onNavigate: (String) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                NoteInspectorSection("Properties") {
                    NotePropertiesView(
                        properties: $vm.properties,
                        onCommit: { vm.updateProperties($0) },
                        optionSuggestions: vm.propertyOptionSuggestions,
                        showsHeader: false
                    )
                    .padding(.horizontal, -DesignTokens.Spacing.md)
                    .padding(.vertical, -DesignTokens.Spacing.sm)
                    .accessibilityLabel("Note properties")
                }

                NoteInspectorSection("Backlinks · \(vm.backlinks.count)") {
                    if vm.backlinks.isEmpty {
                        NoteInspectorPlaceholder("No notes link here")
                    } else {
                        ForEach(vm.backlinks) { note in
                            NoteInspectorRow(systemImage: "doc.text",
                                             title: note.title.isEmpty ? "Untitled" : note.title) {
                                onNavigate(note.id)
                            }
                        }
                    }
                }

                NoteInspectorSection("Outline") { outline }

                NoteInspectorSection("Linked Meetings") {
                    if vm.sessions.isEmpty {
                        NoteInspectorPlaceholder("No recordings")
                    } else {
                        ForEach(vm.sessions) { session in
                            NoteInspectorRow(systemImage: "waveform",
                                             title: Self.meetingTitle(session),
                                             subtitle: NoteDetailView.sessionSubtitle(session)) {
                                // From a note window the main window may be in
                                // the background (or closed): bring it forward
                                // first — it observes the navigation request.
                                openWindow(id: "main")
                                NotificationCenter.default.post(name: .scribeNavigate,
                                                                object: MainSelection.session(session.id))
                            }
                            .help("Open this recording in the main window")
                        }
                    }
                }

                NotePowerInspectorSections(vm: vm, onNavigate: onNavigate)

                NoteInspectorSection("Info") { info }
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.Palette.ground)
        .accessibilityLabel("Note inspector")
    }

    @ViewBuilder
    private var outline: some View {
        let live = editorModel?.outline ?? []
        if !live.isEmpty, let editorModel {
            ForEach(live) { heading in
                NoteInspectorRow(title: heading.text, indent: heading.level - 1) {
                    editorModel.scrollTo(heading)
                }
            }
        } else {
            let parsed = NoteDetailView.headings(in: vm.note.body)
            if parsed.isEmpty {
                NoteInspectorPlaceholder("No headings")
            } else {
                ForEach(parsed) { heading in
                    NoteInspectorRow(title: heading.title, indent: heading.level - 1) {
                        editorModel?.perform(.scrollToLine(Self.line(ofOffset: heading.offset, in: vm.note.body)))
                    }
                }
            }
        }
    }

    private var info: some View {
        let stats = NoteStatistics.compute(body: vm.note.body)
        return VStack(alignment: .leading, spacing: 5) {
            infoRow("Created", vm.note.createdAt.formatted(date: .abbreviated, time: .shortened))
            infoRow("Modified", vm.note.updatedAt.formatted(date: .abbreviated, time: .shortened))
            infoRow("Words", "\(stats.words)")
            infoRow("Characters", "\(stats.characters)")
            infoRow("Reading time", NoteStatistics.readingTimeLabel(minutes: stats.readingMinutes))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
            Spacer(minLength: DesignTokens.Spacing.sm)
            Text(value)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(DesignTokens.Notes.inspectorBody)
        .accessibilityElement(children: .combine)
    }

    /// 1-based line holding the UTF-16 `offset`.
    nonisolated static func line(ofOffset offset: Int, in body: String) -> Int {
        let ns = body as NSString
        let end = min(max(0, offset), ns.length)
        var line = 1
        var index = 0
        while index < end {
            let range = ns.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: index, length: end - index))
            guard range.location != NSNotFound else { break }
            line += 1
            index = range.location + range.length
        }
        return line
    }

    /// The calendar event's title when the recording was matched to one.
    static func meetingTitle(_ session: Session) -> String {
        if let event = session.calendarEventTitle, !event.isEmpty { return event }
        return session.title.isEmpty ? "Untitled recording" : session.title
    }
}

// MARK: - Inspector building blocks

struct NoteInspectorSection<Content: View, Accessory: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(_ title: String,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(title)
                    .font(DesignTokens.Notes.inspectorHeader)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                accessory
            }
            VStack(alignment: .leading, spacing: 2) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NoteInspectorSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

struct NoteInspectorPlaceholder: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DesignTokens.Notes.inspectorBody)
            .foregroundStyle(DesignTokens.Palette.textTertiary)
    }
}

/// A clickable inspector line with a hover wash.
struct NoteInspectorRow: View {
    var systemImage: String? = nil
    let title: String
    var subtitle: String? = nil
    var indent: Int = 0
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                        .frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(DesignTokens.Notes.inspectorBody)
            .padding(.leading, CGFloat(indent) * 10 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(isHovered ? DesignTokens.Palette.selectionFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { isHovered = $0 }
    }
}
