import AppKit
import SwiftUI

/// "Reveal in Finder" and "Copy Link" for a note — shared by the note list,
/// the sidebar notebook tree and the note detail's toolbar menu.
@MainActor
enum NoteLinkActions {

    /// The note's Markdown file in the vault, or nil when it has no file
    /// (no vault configured, or the file was removed externally).
    static func fileURL(noteId: String) -> URL? {
        NoteStore.shared.diskEntry(forNoteId: noteId)?.url
    }

    static func revealInFinder(noteId: String) {
        guard let url = fileURL(noteId: noteId) else {
            AppState.shared.report("This note's file couldn't be found in the notes folder.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Puts `scribe://note/<id>` on the pasteboard (as both a URL and plain
    /// text, so it pastes as a link where links are supported).
    static func copyLink(noteId: String) {
        guard let url = ScribeDeepLink.noteURL(id: noteId) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        pasteboard.setString(url.absoluteString, forType: .URL)
        AppState.shared.notify("Link copied")
    }
}

/// The two menu items, for a note's context menu or a `Menu`.
struct NoteLinkMenuItems: View {
    let noteId: String

    var body: some View {
        Button {
            NoteLinkActions.revealInFinder(noteId: noteId)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Button {
            NoteLinkActions.copyLink(noteId: noteId)
        } label: {
            Label("Copy Link", systemImage: "link")
        }
    }
}

/// Note detail: advertises the open note for Handoff / search
/// (`com.varij.scribe.viewNote`) and adds a toolbar menu with Reveal in
/// Finder and Copy Link.
struct NoteEntryPointsModifier: ViewModifier {
    let noteId: String
    let title: String
    @AppStorage(EntryPointSettings.handoffEnabledKey) private var handoffEnabled = true

    func body(content: Content) -> some View {
        let id = noteId
        let displayTitle = title.isEmpty ? "Untitled" : title
        return content
            .userActivity(ScribeUserActivity.viewNote, isActive: handoffEnabled) { activity in
                ScribeActivityPublisher.configure(activity, id: id, title: displayTitle)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        NoteLinkMenuItems(noteId: id)
                    } label: {
                        Label("Note Actions", systemImage: "ellipsis.circle")
                    }
                    .help("Reveal in Finder, Copy Link")
                }
            }
    }
}

/// Task detail: advertises the open task for Handoff / search
/// (`com.varij.scribe.viewTask`).
struct TaskHandoffModifier: ViewModifier {
    let taskId: String
    let title: String
    @AppStorage(EntryPointSettings.handoffEnabledKey) private var handoffEnabled = true

    func body(content: Content) -> some View {
        let id = taskId
        let displayTitle = title.isEmpty ? "Untitled Task" : title
        return content
            .userActivity(ScribeUserActivity.viewTask, isActive: handoffEnabled) { activity in
                ScribeActivityPublisher.configure(activity, id: id, title: displayTitle)
            }
    }
}

enum ScribeActivityPublisher {
    /// Fills a Scribe note/task activity: id + title in `userInfo`, eligible
    /// for Handoff and on-device search.
    nonisolated static func configure(_ activity: NSUserActivity, id: String, title: String) {
        activity.title = title
        activity.userInfo = [ScribeUserActivity.idKey: id, "title": title]
        activity.requiredUserInfoKeys = [ScribeUserActivity.idKey]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.targetContentIdentifier = id
    }
}
