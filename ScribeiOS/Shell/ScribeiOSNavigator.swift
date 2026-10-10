import CoreSpotlight
import Foundation
import Observation
import SwiftUI
import UIKit

// The iOS shell's per-scene navigation state, and the small contract area
// roots (Notes, Tasks, Record) use to receive "open this" requests from
// entry points (scribe:// links, Handoff, Spotlight, keyboard shortcuts, the
// New Task sheet).
//
// CONTRACT FOR AREA ROOTS
// -----------------------
// The shell never pushes into an area's NavigationStack itself (each area
// owns its own stack / path type). Instead it selects the area's tab and
// posts a one-shot request; the area root applies one modifier to its stack:
//
//     NavigationStack(path: $path) { … }
//         .onScribeOpenRequest(.note) { id in path = [id] }
//
// The request is consumed (cleared) once delivered, and delivery also
// happens on first appear, so a request posted before the tab was ever shown
// still lands. Detail screens add `.scribeHandoff(.note, id:title:)` to
// advertise themselves for Handoff (iPad → Mac) and scene restoration, and
// note rows add `.scribeNoteRowAffordances(noteId:title:)` for "Open in New
// Window", drag-to-new-window, Copy Link and the pointer hover effect.

/// A one-shot "open this id" request. The token makes two requests for the
/// same id distinct, so tapping the same Spotlight result twice re-opens it.
struct ScribeOpenRequest: Equatable, Sendable {
    let token: UUID
    let targetId: String

    init(targetId: String) {
        self.token = UUID()
        self.targetId = targetId
    }
}

/// A one-shot capture command for the Record tab.
struct ScribeRecordRequest: Equatable, Sendable {
    let token: UUID
    let command: ScribeMobileRecordCommand

    init(command: ScribeMobileRecordCommand) {
        self.token = UUID()
        self.command = command
    }
}

/// What an area root asks `onScribeOpenRequest` to deliver.
enum ScribeOpenRequestKind: Sendable {
    case note
    case task
    case meeting
}

@MainActor
@Observable
final class ScribeiOSNavigator {
    /// The scene's selected tab (persisted per scene by RootTabView's
    /// `@SceneStorage`).
    var selectedTab: ScribeMobileTab

    private(set) var noteRequest: ScribeOpenRequest?
    private(set) var taskRequest: ScribeOpenRequest?
    private(set) var meetingRequest: ScribeOpenRequest?
    /// Read by the Record area (RecordingsRootView) to start/stop capture.
    var recordRequest: ScribeRecordRequest?

    /// The Search tab's query; the search screen adopts it whenever
    /// `searchFocusToken` changes.
    private(set) var searchQuery: String = ""
    private(set) var searchFocusToken: Int = 0

    var isNewTaskSheetPresented = false
    /// A user-facing failure (e.g. a link to a note that no longer exists).
    var alertMessage: String?

    /// The note open in this scene's Notes tab, for `@SceneStorage`
    /// restoration. Maintained by `.scribeHandoff(.note, …)`.
    var visibleNoteId: String?

    /// Whether any entry point has routed this scene yet (restoration must
    /// not override a cold-launch deep link).
    private(set) var hasRouted = false

    private let noteStore: NoteStore
    private let taskStore: TaskStore

    init(selectedTab: ScribeMobileTab, noteStore: NoteStore, taskStore: TaskStore) {
        self.selectedTab = selectedTab
        self.noteStore = noteStore
        self.taskStore = taskStore
    }

    // MARK: - Routing

    func show(_ route: ScribeMobileRoute) {
        hasRouted = true
        switch route {
        case .tab(let tab):
            if tab == .search {
                focusSearch(query: "")
            } else {
                selectedTab = tab
            }
        case .note(let id):
            openNote(id)
        case .noteByTitle(let title):
            if let note = try? noteStore.resolveTitle(title) {
                openNote(note.id)
            } else {
                // Unknown title: search for it rather than silently creating
                // a note from an external link (same as the Mac).
                focusSearch(query: title)
            }
        case .newNote(let title, let body):
            createNote(title: title ?? "", body: body ?? "")
        case .task(let id):
            openTask(id)
        case .newTask(let title, let due):
            createTask(title: title, dueText: due)
        case .search(let query):
            focusSearch(query: query)
        case .record(let command):
            selectedTab = .record
            // Settings › Links & Handoff › "Links can start recording".
            guard EntryPointSettings.bool(EntryPointSettings.allowCaptureLinksKey) else { return }
            recordRequest = ScribeRecordRequest(command: command)
        case .meeting(let sessionId):
            selectedTab = .record
            meetingRequest = ScribeOpenRequest(targetId: sessionId)
        }
    }

    /// `scribe://…` from `.onOpenURL`. Returns false for a URL Scribe does
    /// not understand.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let route = ScribeMobileRoute.from(url: url) else { return false }
        show(route)
        return true
    }

    /// A continued Handoff / Spotlight / note-window activity.
    @discardableResult
    func handle(activity: NSUserActivity) -> Bool {
        if activity.activityType == CSSearchableItemActionType {
            guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let route = ScribeMobileRoute.fromSpotlightIdentifier(raw) else { return false }
            show(route)
            return true
        }
        guard let route = ScribeMobileRoute.fromActivity(
            type: activity.activityType,
            userInfo: activity.userInfo
        ) else { return false }
        show(route)
        return true
    }

    // MARK: - Actions

    func openNote(_ id: String) {
        hasRouted = true
        selectedTab = .notes
        noteRequest = ScribeOpenRequest(targetId: id)
    }

    func openTask(_ id: String) {
        hasRouted = true
        selectedTab = .tasks
        taskRequest = ScribeOpenRequest(targetId: id)
    }

    /// ⌘N / the floating New button: creates an empty note and opens it.
    func newNote() {
        createNote(title: "", body: "")
    }

    /// ⌘⇧N / the floating New button: the quick-add task sheet.
    func presentNewTask() {
        isNewTaskSheetPresented = true
    }

    /// ⌘F / ⌘K: selects the Search tab and focuses its field.
    func focusSearch(query: String) {
        hasRouted = true
        searchQuery = query
        selectedTab = .search
        searchFocusToken &+= 1
    }

    private func createNote(title: String, body: String) {
        do {
            let note = try noteStore.createNote(title: title, body: body)
            openNote(note.id)
        } catch {
            alertMessage = "Couldn't create the note: \(error.localizedDescription)"
        }
    }

    private func createTask(title: String, dueText: String?) {
        let dueAt = ScribeMobileTaskCreation.dueDate(fromLinkValue: dueText, now: Date(), calendar: .current)
        do {
            let task = try taskStore.createTask(title: title, dueAt: dueAt)
            openTask(task.id)
        } catch {
            alertMessage = "Couldn't create the task: \(error.localizedDescription)"
        }
    }

    // MARK: - Request delivery

    func pendingRequest(_ kind: ScribeOpenRequestKind) -> ScribeOpenRequest? {
        switch kind {
        case .note:    return noteRequest
        case .task:    return taskRequest
        case .meeting: return meetingRequest
        }
    }

    /// Returns the pending request's id and clears it.
    func consumeRequest(_ kind: ScribeOpenRequestKind) -> String? {
        switch kind {
        case .note:
            defer { noteRequest = nil }
            return noteRequest?.targetId
        case .task:
            defer { taskRequest = nil }
            return taskRequest?.targetId
        case .meeting:
            defer { meetingRequest = nil }
            return meetingRequest?.targetId
        }
    }
}

// MARK: - Focused scene value (menu bar commands)

struct ScribeiOSNavigatorFocusKey: FocusedValueKey {
    typealias Value = ScribeiOSNavigator
}

extension FocusedValues {
    /// The key scene's navigator — the target of the iPad menu bar /
    /// hardware-keyboard commands (ScribeiOSCommands).
    var scribeiOSNavigator: ScribeiOSNavigator? {
        get { self[ScribeiOSNavigatorFocusKey.self] }
        set { self[ScribeiOSNavigatorFocusKey.self] = newValue }
    }
}

// MARK: - Area modifiers

/// Delivers the shell's one-shot open requests of one kind to an area root.
private struct ScribeOpenRequestConsumer: ViewModifier {
    let kind: ScribeOpenRequestKind
    let perform: (String) -> Void

    @Environment(ScribeiOSNavigator.self) private var navigator: ScribeiOSNavigator?

    func body(content: Content) -> some View {
        content
            .onAppear { deliver() }
            .onChange(of: navigator?.pendingRequest(kind)?.token) { _, _ in deliver() }
    }

    private func deliver() {
        guard let navigator, let id = navigator.consumeRequest(kind) else { return }
        perform(id)
    }
}

/// Publishes the open note / task as a Handoff activity (the same
/// `com.varij.scribe.viewNote` / `viewTask` types the Mac continues) and
/// records the visible note for scene restoration.
private struct ScribeHandoffModifier: ViewModifier {
    let kind: ScribeOpenRequestKind
    let id: String
    let title: String

    @AppStorage(EntryPointSettings.handoffEnabledKey) private var handoffEnabled = true
    @Environment(ScribeiOSNavigator.self) private var navigator: ScribeiOSNavigator?

    func body(content: Content) -> some View {
        let activityType = kind == .task ? ScribeUserActivity.viewTask : ScribeUserActivity.viewNote
        let itemId = id
        let displayTitle = title.isEmpty ? (kind == .task ? "Untitled Task" : "Untitled") : title
        return content
            .userActivity(activityType, isActive: handoffEnabled && kind != .meeting) { activity in
                ScribeiOSActivity.configureHandoff(activity, id: itemId, title: displayTitle)
            }
            .onAppear {
                guard kind == .note, let navigator, navigator.selectedTab == .notes else { return }
                navigator.visibleNoteId = itemId
            }
            .onDisappear {
                // Only a pop inside the Notes tab clears it; switching tabs
                // (selectedTab already changed) keeps it for restoration.
                guard kind == .note, let navigator, navigator.selectedTab == .notes,
                      navigator.visibleNoteId == itemId else { return }
                navigator.visibleNoteId = nil
            }
    }
}

/// iPad / pointer affordances for a note row: hover highlight, a context
/// menu with Open in New Window and Copy Link, and a drag item that opens a
/// note window when dropped at the screen edge. Rows that already have a
/// context menu of their own pass `contextMenu: false` and put
/// `ScribeNoteRowMenuItems` inside theirs (two `.contextMenu`s on one row
/// would hide one of them).
private struct ScribeNoteRowAffordances: ViewModifier {
    let noteId: String
    let title: String
    let includesContextMenu: Bool

    func body(content: Content) -> some View {
        withMenu(content)
            .hoverEffect(.highlight)
            .onDrag {
                ScribeiOSActivity.noteWindowDragItem(noteId: noteId, title: title)
            }
    }

    @ViewBuilder
    private func withMenu(_ content: Content) -> some View {
        if includesContextMenu {
            content.contextMenu {
                ScribeNoteRowMenuItems(noteId: noteId)
            }
        } else {
            content
        }
    }
}

/// Open in New Window (when the device supports multiple windows) and Copy
/// Link, for a note row's context menu.
struct ScribeNoteRowMenuItems: View {
    let noteId: String

    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some View {
        if supportsMultipleWindows {
            Button {
                openWindow(id: ScribeMobileWindows.noteWindowGroupID, value: noteId)
            } label: {
                Label("Open in New Window", systemImage: "plus.rectangle.on.rectangle")
            }
        }
        Button {
            UIPasteboard.general.url = ScribeDeepLink.noteURL(id: noteId)
        } label: {
            Label("Copy Link", systemImage: "link")
        }
    }
}

extension View {
    /// Area roots: receive the shell's "open this note/task/meeting"
    /// requests (see the contract at the top of ScribeiOSNavigator.swift).
    func onScribeOpenRequest(_ kind: ScribeOpenRequestKind, perform: @escaping (String) -> Void) -> some View {
        modifier(ScribeOpenRequestConsumer(kind: kind, perform: perform))
    }

    /// Detail screens: advertise the item for Handoff + scene restoration.
    func scribeHandoff(_ kind: ScribeOpenRequestKind, id: String, title: String) -> some View {
        modifier(ScribeHandoffModifier(kind: kind, id: id, title: title))
    }

    /// Note rows: Open in New Window, drag-to-window, Copy Link, hover.
    /// Pass `contextMenu: false` when the row has its own context menu and
    /// add `ScribeNoteRowMenuItems(noteId:)` to it instead.
    func scribeNoteRowAffordances(noteId: String, title: String, contextMenu: Bool = true) -> some View {
        modifier(ScribeNoteRowAffordances(noteId: noteId, title: title, includesContextMenu: contextMenu))
    }
}

// MARK: - NSUserActivity helpers

enum ScribeiOSActivity {
    /// Fills a Handoff activity exactly like the Mac's
    /// `ScribeActivityPublisher.configure` so either side can continue it.
    nonisolated static func configureHandoff(_ activity: NSUserActivity, id: String, title: String) {
        activity.title = title
        activity.userInfo = [ScribeUserActivity.idKey: id, "title": title]
        activity.requiredUserInfoKeys = [ScribeUserActivity.idKey]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.targetContentIdentifier = id
    }

    /// The drag item for a note row: an `NSUserActivity` (which iPadOS turns
    /// into a new note window when dropped at the screen edge) plus the
    /// note's scribe:// link for drops into other apps.
    nonisolated static func noteWindowDragItem(noteId: String, title: String) -> NSItemProvider {
        let activity = NSUserActivity(activityType: ScribeMobileWindows.openNoteWindowActivityType)
        activity.title = title.isEmpty ? "Untitled" : title
        activity.userInfo = [ScribeUserActivity.idKey: noteId]
        activity.targetContentIdentifier = ScribeMobileWindows.noteWindowTargetContentIdentifier
        let provider = NSItemProvider()
        // NSUserActivity conforms to NSItemProviderWriting on iOS (UIKit),
        // which is what lets a drag spawn a scene.
        // CI-COMPILE NOTE: if the SDK isolates that conformance to the main
        // actor, mark this function (and the enum) `@MainActor`.
        provider.registerObject(activity, visibility: .all)
        if let url = ScribeDeepLink.noteURL(id: noteId) {
            provider.registerObject(url as NSURL, visibility: .all)
        }
        return provider
    }
}
