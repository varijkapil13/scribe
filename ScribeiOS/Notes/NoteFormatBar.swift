// ScribeiOS/Notes/NoteFormatBar.swift
//
// The keyboard accessory bar of the iPhone / iPad note editor. Sits on top of
// the software keyboard (the editor places it in a bottom safe-area inset,
// which SwiftUI lifts above the keyboard) and sends format commands to the
// CodeMirror page through `EditorCommandBridge` → `window.scribeCommand`,
// exactly like the Mac's Format menu. Image / camera / scan buttons hand off
// to the attachment pickers.

import SwiftUI
import UIKit

struct NoteFormatBar: View {
    let bridge: EditorCommandBridge
    var onPhotoLibrary: () -> Void
    var onCamera: (() -> Void)?
    var onScan: (() -> Void)?
    var onDismissKeyboard: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    button("Bold", "bold", .bold, shortcut: "b")
                    button("Italic", "italic", .italic, shortcut: "i")
                    Menu {
                        Button("Heading 1") { bridge.perform(.heading(1)) }
                        Button("Heading 2") { bridge.perform(.heading(2)) }
                        Button("Heading 3") { bridge.perform(.heading(3)) }
                        Button("Body Text") { bridge.perform(.heading(0)) }
                    } label: {
                        barIcon("textformat.size")
                    }
                    .accessibilityLabel("Heading")
                    button("Bulleted List", "list.bullet", .bulletedList)
                    button("Numbered List", "list.number", .numberedList)
                    button("Checklist", "checklist", .checklist)
                    button("Quote", "text.quote", .quote)
                    button("Link", "link", .link)
                    button("Note Link", "link.badge.plus", .wikiLink)
                    Divider().frame(height: 22).padding(.horizontal, 4)
                    Menu {
                        Button(action: onPhotoLibrary) {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        if let onCamera {
                            Button(action: onCamera) {
                                Label("Take Photo", systemImage: "camera")
                            }
                        }
                        if let onScan {
                            Button(action: onScan) {
                                Label("Scan Document", systemImage: "doc.viewfinder")
                            }
                        }
                    } label: {
                        barIcon("photo")
                    }
                    .accessibilityLabel("Insert Image")
                    Divider().frame(height: 22).padding(.horizontal, 4)
                    button("Undo", "arrow.uturn.backward", .undo)
                    button("Redo", "arrow.uturn.forward", .redo)
                }
                .padding(.horizontal, 6)
            }
            Divider().frame(height: 22)
            Button(action: onDismissKeyboard) {
                barIcon("keyboard.chevron.compact.down")
            }
            .accessibilityLabel("Hide Keyboard")
            .padding(.horizontal, 4)
        }
        .frame(height: 44)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func button(_ title: String, _ systemImage: String, _ command: EditorCommand,
                        shortcut: KeyEquivalent? = nil) -> some View {
        Button {
            bridge.perform(command)
        } label: {
            barIcon(systemImage)
        }
        .accessibilityLabel(title)
        .modifier(OptionalShortcut(key: shortcut))
    }

    private func barIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .regular))
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }
}

/// ⌘B / ⌘I on an iPad hardware keyboard.
private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}

/// Tracks whether the software keyboard (or the iPad shortcuts bar) is up,
/// so the editor shows the format bar only while typing.
@MainActor
@Observable
final class KeyboardVisibility {
    private(set) var isVisible = false

    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    /// Cheap (SwiftUI may create throwaway instances); observing starts in
    /// `start()`.
    init() {}

    func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = true }
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = false }
        })
    }

    func stop() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }
}
