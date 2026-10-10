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
/// Inspector (⌥⌘I) act on it. Visibility is remembered per window.
struct NoteInspectorModifier: ViewModifier {
    @ObservedObject var vm: NoteDetailViewModel
    let onNavigate: (String) -> Void
    @SceneStorage("scribe.noteInspector.isPresented") private var isPresented = false

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: $isPresented) {
                NoteInspectorView(vm: vm, onNavigate: onNavigate)
                    .inspectorColumnWidth(min: 220, ideal: 260, max: 380)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresented.toggle()
                    } label: {
                        Label(isPresented ? "Hide Inspector" : "Show Inspector",
                              systemImage: "sidebar.trailing")
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

/// Note info: dates, counts, reading time, tags, linked meetings and backlinks.
struct NoteInspectorView: View {
    @ObservedObject var vm: NoteDetailViewModel
    let onNavigate: (String) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let stats = NoteStatistics.compute(body: vm.note.body)
        Form {
            Section("Info") {
                LabeledContent("Created") {
                    Text(vm.note.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Modified") {
                    Text(vm.note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Words") { Text("\(stats.words)").monospacedDigit() }
                LabeledContent("Characters") { Text("\(stats.characters)").monospacedDigit() }
                LabeledContent("Reading time") {
                    Text(NoteStatistics.readingTimeLabel(minutes: stats.readingMinutes))
                }
                if !vm.tags.isEmpty {
                    LabeledContent("Tags") {
                        Text(vm.tags.map { "#\($0)" }.joined(separator: " "))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            Section("Linked Meetings") {
                if vm.sessions.isEmpty {
                    Text("No recordings")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.sessions) { session in
                        Button {
                            // From a note window the main window may be in
                            // the background (or closed): bring it forward
                            // first — it observes the navigation request.
                            openWindow(id: "main")
                            NotificationCenter.default.post(name: .scribeNavigate,
                                                            object: MainSelection.session(session.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.meetingTitle(session))
                                    .lineLimit(2)
                                Text(NoteDetailView.sessionSubtitle(session))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open this recording in the main window")
                    }
                }
            }

            Section("Backlinks") {
                if vm.backlinks.isEmpty {
                    Text("No notes link here")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.backlinks) { note in
                        Button {
                            onNavigate(note.id)
                        } label: {
                            Label(note.title.isEmpty ? "Untitled" : note.title,
                                  systemImage: "doc.text")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityLabel("Note inspector")
    }

    /// The calendar event's title when the recording was matched to one.
    static func meetingTitle(_ session: Session) -> String {
        if let event = session.calendarEventTitle, !event.isEmpty { return event }
        return session.title.isEmpty ? "Untitled recording" : session.title
    }
}
