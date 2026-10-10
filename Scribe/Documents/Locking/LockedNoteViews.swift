// Scribe/Documents/Locking/LockedNoteViews.swift
import SwiftUI

/// Shown in place of the editor while a locked note isn't unlocked.
struct LockedNoteUnlockView: View {
    let title: String
    let onUnlock: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "lock.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("This note is locked")
                .font(.title3.weight(.semibold))
            Text("\u{201C}\(title.isEmpty ? "Untitled" : title)\u{201D} is encrypted on disk. Its contents stay out of search, Spotlight and the MCP server, and are only kept in memory while unlocked.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onUnlock) {
                Label("Unlock with Touch ID", systemImage: "touchid")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Asks for Touch ID or your login password")
            Text("You can also use your login password.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Locked note")
    }
}

/// The note toolbar's Document menu: lock / unlock, attachments with
/// recognized text (Live Text), and HTML export.
struct NoteDocumentsModifier: ViewModifier {
    @ObservedObject var vm: NoteDetailViewModel
    @State private var showsAttachments = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        lockItems
                        Divider()
                        Button("Attachments & Recognized Text…") { showsAttachments = true }
                            .disabled(vm.lockPhase == .locked)
                        Button("Export as HTML…") {
                            vm.flushPendingSave()
                            NoteHTMLExport.exportInteractively(note: vm.note)
                        }
                        .disabled(vm.lockPhase == .locked)
                    } label: {
                        Label("Document", systemImage: vm.isLockedNote ? "lock.doc" : "doc.text.magnifyingglass")
                    }
                    .help(vm.isLockedNote ? "Locked note, attachments and export" : "Lock, attachments and export")
                }
            }
            .sheet(isPresented: $showsAttachments) {
                NoteAttachmentsSheet(noteId: vm.note.id, noteTitle: vm.note.title)
            }
    }

    @ViewBuilder
    private var lockItems: some View {
        switch vm.lockPhase {
        case .notLocked:
            Button("Lock Note…") {
                Task { await vm.lockNote() }
            }
            // Daily notes are appended to by Quick Capture and the daily view.
            .disabled(vm.note.isDailyNote)
        case .locked:
            Button("Unlock Note…") {
                Task { await vm.unlockNote() }
            }
        case .unlocked:
            Button("Lock Now") {
                LockedNoteSession.shared.lock()
            }
            Button("Remove Lock") {
                vm.removeLock()
            }
        }
    }
}
