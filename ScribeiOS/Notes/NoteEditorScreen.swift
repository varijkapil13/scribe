// ScribeiOS/Notes/NoteEditorScreen.swift
//
// One note on iPhone / iPad: title, tags, and the shared CodeMirror editor
// (IOSWebMarkdownEditor) with the keyboard format bar, `[[wiki link]]`
// navigation, attachments (photo library, camera, document scanner), the
// inspector (backlinks, unlinked mentions, outline, info), templates, version
// history, locking, and daily-note day stepping.
//
// `NoteEditorScreen(noteId:)` also works pushed onto any NavigationStack (the
// Today screen does that): linked notes then push on the same stack. The
// notes browser passes `onOpenNote` to route links through its own navigation.

import PhotosUI
import SwiftUI
import UIKit

struct NoteEditorScreen: View {
    let noteId: String
    /// Opens another note (wiki links, backlinks). nil → push it on the
    /// enclosing NavigationStack.
    var onOpenNote: ((String) -> Void)? = nil
    /// The note was deleted from this screen.
    var onDeleted: (() -> Void)? = nil

    @State private var model: IOSNoteEditorModel
    @State private var editorModel = WebEditorModel()
    @State private var bridge = EditorCommandBridge()
    @State private var keyboard = KeyboardVisibility()
    @State private var knownTitles: [String] = []

    @State private var newTag = ""
    @State private var showInspector = false
    @State private var showHistory = false
    @State private var templateMode: NoteTemplateSheet.Mode?
    @State private var showPhotoPicker = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showScanner = false
    @State private var pushedNoteId: String?
    @State private var missingLinkTitle: String?
    @State private var confirmDelete = false

    @AppStorage(PlantUMLRenderingPreference.remoteEnabledKey) private var plantUMLRemote = PlantUMLRenderingPreference.defaultValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss

    private let store: NoteStore

    init(noteId: String, onOpenNote: ((String) -> Void)? = nil, onDeleted: (() -> Void)? = nil) {
        self.noteId = noteId
        self.onOpenNote = onOpenNote
        self.onDeleted = onDeleted
        let store = NoteStore.shared
        self.store = store
        _model = State(initialValue: IOSNoteEditorModel(noteId: noteId, store: store))
    }

    var body: some View {
        alerts(presentations(chrome(content)))
            .onAppear {
                model.activate()
                keyboard.start()
                refreshTitles()
            }
            .onDisappear {
                model.deactivate()
                keyboard.stop()
            }
            .task(id: noteId) { await applyPendingScroll() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.flush() }
            }
    }

    /// Title, toolbar, inspector, linked-note pushes.
    private func chrome(_ base: some View) -> some View {
        base
            .navigationTitle(model.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            // Shell contract: Handoff to the Mac + per-window restoration.
            .scribeHandoff(.note, id: noteId, title: model.displayTitle)
            .toolbar { toolbarContent }
            .inspector(isPresented: $showInspector) {
                NoteInspectorPanel(editor: model, editorCommands: editorModel, store: store) { id in
                    open(id)
                }
                .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
            }
            .navigationDestination(item: $pushedNoteId) { id in
                NoteEditorScreen(noteId: id)
            }
    }

    /// History, templates and the attachment sources.
    private func presentations(_ base: some View) -> some View {
        base
            .sheet(isPresented: $showHistory) {
                NoteVersionHistoryView(
                    noteId: noteId,
                    store: store,
                    flushEditor: { model.flush() },
                    onRestored: { model.reloadFromDisk() }
                )
            }
            .sheet(item: templateSheetBinding) { token in
                NoteTemplateSheet(mode: token.mode, library: NoteTemplateLibrary.iosCurrentVault(store: store)) { file, _ in
                    insertTemplate(file)
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhotos,
                          maxSelectionCount: 10, matching: .images)
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                Task {
                    let files = await NoteAttachmentSources.files(from: items)
                    importFiles(files)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                NoteCameraPicker(onImage: { image in
                    showCamera = false
                    if let file = NoteAttachmentSources.file(fromCameraImage: image) { importFiles([file]) }
                }, onCancel: { showCamera = false })
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showScanner) {
                NoteDocumentScanner(onPages: { pages in
                    showScanner = false
                    importFiles(NoteAttachmentSources.files(fromScanPages: pages))
                }, onCancel: { showScanner = false })
                .ignoresSafeArea()
            }
    }

    /// Missing-link, error and delete prompts.
    private func alerts(_ base: some View) -> some View {
        base
            .alert(missingLinkAlertTitle, isPresented: missingLinkBinding) {
                Button("Create Note") { createLinkedNote() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Create it now? The link will point to the new note.")
            }
            .alert("Note", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Note", role: .destructive) { deleteNote() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The note's file is removed from your notes folder.")
            }
    }

    private var templateSheetBinding: Binding<TemplateSheetToken?> {
        Binding(
            get: { templateMode.map { TemplateSheetToken(mode: $0) } },
            set: { templateMode = $0?.mode }
        )
    }

    private var missingLinkAlertTitle: String {
        "No Note Named \u{201C}\(missingLinkTitle ?? "")\u{201D}"
    }

    private var missingLinkBinding: Binding<Bool> {
        Binding(get: { missingLinkTitle != nil }, set: { if !$0 { missingLinkTitle = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.exists {
            ContentUnavailableView(
                "Note Not Found",
                systemImage: "doc.questionmark",
                description: Text("It may have been deleted on another device.")
            )
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                if model.lockPhase == .locked {
                    lockedPlaceholder
                } else {
                    editor
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: Binding(get: { model.title }, set: { model.setTitle($0) }))
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .submitLabel(.next)
                .accessibilityLabel("Note title")
            tagsRow
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var tagsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text("#\(tag)").font(.caption)
                        Button {
                            model.removeTag(tag)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                HStack(spacing: 4) {
                    Image(systemName: "tag").font(.caption).foregroundStyle(.secondary)
                    TextField("Add tag", text: $newTag)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .frame(minWidth: 80)
                        .onSubmit {
                            model.addTag(newTag)
                            newTag = ""
                        }
                }
            }
        }
    }

    private var editor: some View {
        IOSWebMarkdownEditor(
            text: Binding(get: { model.body }, set: { model.setBody($0) }),
            colorScheme: colorScheme,
            fontSize: IOSEditorFontSize.points(for: dynamicTypeSize),
            knownTitles: knownTitles,
            onWikiLink: { anchor in followWikiLink(anchor) },
            plantUMLRemoteEnabled: plantUMLRemote,
            commandBridge: bridge,
            attachmentNoteId: noteId,
            completionDataProvider: {
                EditorCompletionData(
                    titles: (try? NoteStore.shared.allNoteTitles()) ?? [],
                    tags: (try? NoteStore.shared.allNoteTags()) ?? []
                )
            },
            model: editorModel,
            onPlatformMessage: { type, body in handlePlatformMessage(type, body) }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboard.isVisible {
                NoteFormatBar(
                    bridge: bridge,
                    onPhotoLibrary: { showPhotoPicker = true },
                    onCamera: cameraAction,
                    onScan: scanAction,
                    onDismissKeyboard: { dismissKeyboard() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var cameraAction: (() -> Void)? {
        guard NoteAttachmentSources.isCameraAvailable else { return nil }
        return { showCamera = true }
    }

    private var scanAction: (() -> Void)? {
        guard NoteAttachmentSources.isScannerAvailable else { return nil }
        return { showScanner = true }
    }

    private var lockedPlaceholder: some View {
        ContentUnavailableView {
            Label("This Note Is Locked", systemImage: "lock.fill")
        } description: {
            Text("Unlock it with Face ID, Touch ID or your passcode.")
        } actions: {
            Button {
                Task { await model.unlockNote() }
            } label: {
                Label("Unlock Note", systemImage: "faceid")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.isDailyNote, let date = model.dailyDate {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    openDaily(Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date)
                } label: {
                    Label("Previous Day", systemImage: "chevron.left")
                }
                Button {
                    openDaily(Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date)
                } label: {
                    Label("Next Day", systemImage: "chevron.right")
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Note Info", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Menu {
                noteMenu
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var noteMenu: some View {
        Section {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Add Photos", systemImage: "photo.on.rectangle")
            }
            .disabled(model.lockPhase == .locked)
            if NoteAttachmentSources.isCameraAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                .disabled(model.lockPhase == .locked)
            }
            if NoteAttachmentSources.isScannerAvailable {
                Button {
                    showScanner = true
                } label: {
                    Label("Scan Document", systemImage: "doc.viewfinder")
                }
                .disabled(model.lockPhase == .locked)
            }
            Button {
                templateMode = .insert
            } label: {
                Label("Insert Template", systemImage: "doc.badge.plus")
            }
            .disabled(model.lockPhase == .locked)
        }
        Section {
            Button {
                showHistory = true
            } label: {
                Label("Version History", systemImage: "clock.arrow.circlepath")
            }
            .disabled(model.isLockedNote)
            switch model.lockPhase {
            case .notLocked:
                Button {
                    Task { await model.lockNote() }
                } label: {
                    Label("Lock Note", systemImage: "lock")
                }
            case .unlocked:
                Button {
                    model.relock()
                } label: {
                    Label("Lock Now", systemImage: "lock.fill")
                }
                Button {
                    model.removeLock()
                } label: {
                    Label("Remove Lock", systemImage: "lock.open")
                }
            case .locked:
                Button {
                    Task { await model.unlockNote() }
                } label: {
                    Label("Unlock Note", systemImage: "lock.open")
                }
            }
            if let url = ScribeNoteShareLink.fileURL(noteId: noteId, store: store), model.lockPhase == .notLocked {
                ShareLink(item: url) {
                    Label("Share Markdown File", systemImage: "square.and.arrow.up")
                }
            }
        }
        Section {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Note", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func refreshTitles() {
        knownTitles = (try? store.allNoteTitles()) ?? []
    }

    private func open(_ id: String) {
        guard id != noteId else { return }
        model.flush()
        if let onOpenNote {
            onOpenNote(id)
        } else {
            pushedNoteId = id
        }
    }

    private func openDaily(_ date: Date) {
        guard let daily = try? store.dailyNoteCreatingIfNeeded(for: date) else { return }
        open(daily.note.id)
    }

    private func followWikiLink(_ anchor: String) {
        let store = self.store
        let plan = WikiLinkNavigationPlan.plan(
            anchor: anchor,
            currentNoteId: noteId,
            currentBody: model.body,
            resolve: { anchor in
                (try? store.resolveLinkTarget(anchor: anchor)).map { (id: $0.id, title: $0.title) }
            },
            bodyOf: { id in (try? store.fetchNote(id: id))?.body }
        )
        switch plan {
        case .scrollCurrent(let line):
            editorModel.perform(.scrollToLine(line))
        case .open(let id, let line):
            if let line { IOSPendingEditorScroll.shared.request(noteId: id, line: line) }
            open(id)
        case .missing(let title):
            missingLinkTitle = title
        case .stay:
            break
        }
    }

    private func createLinkedNote() {
        guard let title = missingLinkTitle else { return }
        missingLinkTitle = nil
        do {
            let created = try store.createNote(title: title)
            refreshTitles()
            open(created.id)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func importFiles(_ files: [EditorImportedFile]) {
        guard !files.isEmpty else { return }
        guard let coordinator = editorModel.coordinator else {
            model.errorMessage = "The editor isn't ready yet. Try again in a moment."
            return
        }
        coordinator.importDeviceFiles(files)
    }

    private func insertTemplate(_ file: NoteTemplateFile) {
        guard let library = NoteTemplateLibrary.iosCurrentVault(store: store),
              let rendered = NoteTemplateActions.render(file, library: library, title: model.title) else {
            model.errorMessage = "The template \u{201C}\(file.name)\u{201D} couldn't be read."
            return
        }
        editorModel.perform(NotePowerEditorCommands.insertTemplate(rendered))
    }

    /// Editor messages the shared core leaves to iOS.
    private func handlePlatformMessage(_ type: String, _ body: [String: Any]) -> Bool {
        switch type {
        case "copyText":
            guard let text = body["text"] as? String, !text.isEmpty else { return true }
            UIPasteboard.general.string = text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return true
        case "insertTemplateRequest":
            templateMode = .insert
            return true
        default:
            return false
        }
    }

    private func deleteNote() {
        model.flush()
        do {
            try store.deleteNote(id: noteId)
            if let onDeleted {
                onDeleted()
            } else {
                dismiss()
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    /// Scrolls to a heading / block a `[[Note#Heading]]` link asked for, once
    /// this editor has loaded.
    private func applyPendingScroll() async {
        guard let line = IOSPendingEditorScroll.shared.take(noteId: noteId) else { return }
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            if editorModel.perform(.scrollToLine(line)) { return }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// `.sheet(item:)` needs an Identifiable value.
private struct TemplateSheetToken: Identifiable {
    let mode: NoteTemplateSheet.Mode
    var id: String { mode == .insert ? "insert" : "new" }
}

/// A heading / block line to scroll to once a note's editor loads (after
/// following `[[Note#Heading]]`). iOS counterpart of the Mac's
/// `NoteEditorDeferredScroll`, keyed by note so only that note's editor acts.
@MainActor
final class IOSPendingEditorScroll {
    static let shared = IOSPendingEditorScroll()
    private var pending: [String: Int] = [:]
    private init() {}

    func request(noteId: String, line: Int) { pending[noteId] = line }
    func take(noteId: String) -> Int? { pending.removeValue(forKey: noteId) }
}

/// The editor's body size for the current Dynamic Type setting (the iOS
/// body text style's point sizes).
enum IOSEditorFontSize {
    static func points(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 14
        case .small: return 15
        case .medium: return 16
        case .large: return 17
        case .xLarge: return 19
        case .xxLarge: return 21
        case .xxxLarge: return 23
        case .accessibility1: return 28
        case .accessibility2: return 33
        case .accessibility3: return 40
        case .accessibility4: return 47
        case .accessibility5: return 53
        @unknown default: return 17
        }
    }
}

/// The note's markdown file, for the share sheet.
@MainActor
enum ScribeNoteShareLink {
    static func fileURL(noteId: String, store: NoteStore) -> URL? {
        store.diskEntry(forNoteId: noteId)?.url
    }
}
