import AppKit
import SwiftUI

/// The one place every external entry point lands: `scribe://` links and
/// opened Markdown files (via `AppDelegate.application(_:open:)`), Handoff /
/// search continuations, the Dock menu and the Services menu.
///
/// Navigation is delivered to the main window through the existing
/// `.scribeNavigate` notification while the window is mounted. When it isn't
/// (closed to the menu bar, or a cold launch whose window hasn't appeared
/// yet), the destination is parked and handed over by
/// `ScribeEntryPointsModifier` when the window appears — so a link is never
/// lost and never applied twice.
///
/// Only `AppDelegate.application(_:open:)` feeds URLs in here; nothing uses
/// SwiftUI's `.onOpenURL`, so a link can't be handled twice.
@MainActor
final class ScribeEntryRouter {

    static let shared = ScribeEntryRouter()

    /// Set by `install(delegate:)` at the end of launch. URLs that arrive
    /// earlier (AppKit can deliver the open event during launch) are queued.
    private weak var appDelegate: AppDelegate?
    private var queuedURLs: [URL] = []

    // Main-window bridge (see ScribeEntryPointsModifier).
    private(set) var isMainWindowMounted = false
    private var openMainWindowAction: OpenWindowAction?
    private var pendingSelection: MainSelection?
    private var pendingCommandBar = false
    private var pendingSearchQuery: String?

    /// Strong reference: `NSApp.servicesProvider` must stay alive.
    private let servicesProvider: ScribeServicesProvider

    private init() {
        servicesProvider = ScribeServicesProvider()
    }

    // MARK: - Lifecycle

    /// Called once from `applicationDidFinishLaunching`, after the app state
    /// exists: registers the Services provider and drains queued URLs.
    func install(delegate: AppDelegate) {
        appDelegate = delegate
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        let queued = queuedURLs
        queuedURLs = []
        if !queued.isEmpty { handle(urls: queued) }
    }

    // MARK: - Incoming URLs

    /// Entry point for `application(_:open:)`: `scribe://` links and file
    /// URLs (Markdown documents opened with Scribe).
    func handle(urls: [URL]) {
        guard appDelegate != nil else {
            queuedURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            if url.isFileURL {
                openMarkdownFile(url)
            } else if let link = ScribeDeepLink.parse(url) {
                handle(link)
            } else {
                Log.app.info("Ignoring unsupported URL: \(url.absoluteString, privacy: .private)")
            }
        }
    }

    func handle(_ link: ScribeDeepLink) {
        switch link {
        case .note(let id):
            show(.note(id))
        case .noteByTitle(let title):
            if let note = try? NoteStore.shared.resolveTitle(title) {
                show(.note(note.id))
            } else {
                // Unknown title: search for it rather than silently creating
                // a note from an external link.
                showCommandBar(query: title)
            }
        case .newNote(let title, let body):
            createNote(title: title ?? "", body: body ?? "")
        case .task(let id):
            show(.task(id))
        case .newTask(let title, let due):
            createTask(title: title, notes: "", dueText: due)
        case .meeting(let sessionId):
            show(.session(sessionId))
        case .startRecording:
            guard captureLinksAllowed() else { return }
            startRecording()
        case .stopRecording:
            guard captureLinksAllowed() else { return }
            stopRecording()
        case .dictate:
            guard captureLinksAllowed() else { return }
            DictationController.shared.toggle()
        case .search(let query):
            showCommandBar(query: query)
        case .today:
            show(.today)
        case .importShared:
            ScribeExtensionsBridge.shared.handleImportShareLink()
        }
    }

    /// Handoff / search continuation of a `ScribeUserActivity` type. Returns
    /// false for activities that aren't Scribe's (so a caller can try other
    /// handlers).
    @discardableResult
    func continueActivity(_ activity: NSUserActivity) -> Bool {
        guard let destination = ScribeUserActivity.destination(
            activityType: activity.activityType,
            userInfo: activity.userInfo
        ) else { return false }
        show(destination)
        return true
    }

    // MARK: - Actions (shared by links, Dock menu and Services)

    var isRecording: Bool {
        AppState.shared.isTranscribing || AppState.shared.isStartingSession
    }

    func startRecording() {
        guard let appDelegate, !isRecording else { return }
        Task { await appDelegate.startRecording() }
    }

    func stopRecording() {
        guard let appDelegate, isRecording else { return }
        Task { await appDelegate.stopRecording() }
    }

    func toggleDictation() {
        DictationController.shared.toggle()
    }

    /// Creates a note and opens it.
    func createNote(title: String, body: String) {
        do {
            let note = try NoteStore.shared.createNote(title: title, body: body)
            show(.note(note.id))
        } catch {
            fail("Couldn't create the note: \(error.localizedDescription)")
        }
    }

    /// Creates a task and opens it. `dueText` is a `new-task` `due=` value:
    /// the strict formats first, then the quick-add natural-language parser
    /// ("next friday 5pm").
    func createTask(title: String, notes: String, dueText: String?) {
        var dueAt: Date?
        if let dueText {
            dueAt = ScribeDeepLink.dueDate(from: dueText, now: Date(), calendar: .current)
                ?? QuickAddParser.parse(dueText).dueAt
        }
        do {
            let task = try TaskStore.shared.createTask(title: title, notes: notes, dueAt: dueAt)
            show(.task(task.id))
        } catch {
            fail("Couldn't create the task: \(error.localizedDescription)")
        }
    }

    // MARK: - Markdown documents

    /// A Markdown file opened with Scribe: a note in the vault opens in
    /// place; anything else is imported as a new note (copied into the vault).
    func openMarkdownFile(_ url: URL) {
        let fileStore = NoteStore.shared.fileStore
        let fileURL = url.resolvingSymlinksInPath()
        let root = fileStore?.directory.root.resolvingSymlinksInPath()
        switch MarkdownOpenClassifier.classify(fileURL: fileURL, vaultRoot: root) {
        case .unsupported:
            fail("Scribe can only open Markdown files.")
        case .importCopy:
            importMarkdownFile(url)
        case .vaultNote(let relativePath):
            // Read through the store's own (unresolved) root so the entry's
            // relative path — and so a path-derived id for a file without an
            // `id:` line — matches what the vault indexer computes, even
            // when the vault root sits behind a symlink.
            guard let fileStore,
                  let entry = try? fileStore.readEntry(
                      at: fileStore.directory.root.appendingPathComponent(relativePath)
                  ) else {
                fail("Couldn't read “\(url.lastPathComponent)”.")
                return
            }
            openVaultNote(id: entry.file.id)
        }
    }

    private func openVaultNote(id: String) {
        if (try? NoteStore.shared.fetchNote(id: id)) != nil {
            show(.note(id))
            return
        }
        // A file added moments ago may not be indexed yet; the vault watcher
        // reconciles it within a second or two. Wait briefly, then open.
        Task { @MainActor [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(300))
                if (try? NoteStore.shared.fetchNote(id: id)) != nil { break }
            }
            self?.show(.note(id))
        }
    }

    private func importMarkdownFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let contents = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            // Fresh id: the import is a copy, so it must never collide with
            // (or overwrite) the note the file was exported from.
            let parsed = NoteFrontmatterCodec.decodeFile(
                contents: contents,
                fallbackTitle: MarkdownOpenClassifier.fallbackTitle(for: url),
                fallbackId: UUID().uuidString
            )
            let title = parsed.frontmatter.title.isEmpty
                ? MarkdownOpenClassifier.fallbackTitle(for: url)
                : parsed.frontmatter.title
            let note = try NoteStore.shared.createNote(
                title: title,
                body: parsed.body,
                tags: parsed.frontmatter.tags
            )
            show(.note(note.id))
            AppState.shared.notify("Imported “\(url.lastPathComponent)” into your notes")
        } catch {
            fail("Couldn't import “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    // MARK: - Main-window bridge

    /// What the main window should apply when it appears.
    struct PendingWindowRequest {
        var selection: MainSelection?
        var openCommandBar: Bool
    }

    /// Called by `ScribeEntryPointsModifier.onAppear`. Records that the
    /// window is up, keeps its `openWindow` action for re-opening it later,
    /// and hands over anything parked while it was closed.
    func mainWindowDidAppear(openWindow: OpenWindowAction) -> PendingWindowRequest {
        isMainWindowMounted = true
        openMainWindowAction = openWindow
        let request = PendingWindowRequest(selection: pendingSelection, openCommandBar: pendingCommandBar)
        pendingSelection = nil
        pendingCommandBar = false
        return request
    }

    func mainWindowDidDisappear() {
        isMainWindowMounted = false
    }

    /// The query a `scribe://search` link asked the command bar to show;
    /// consumed once by `UniversalSearchView`.
    func takePendingSearchQuery() -> String? {
        defer { pendingSearchQuery = nil }
        return pendingSearchQuery
    }

    // MARK: - Presentation

    func show(_ selection: MainSelection) {
        if isMainWindowMounted {
            NotificationCenter.default.post(name: .scribeNavigate, object: selection)
        } else {
            pendingSelection = selection
        }
        presentMainWindow()
    }

    func showCommandBar(query: String) {
        pendingSearchQuery = query
        if isMainWindowMounted {
            NotificationCenter.default.post(name: .scribeOpenCommandBar, object: nil)
        } else {
            pendingCommandBar = true
        }
        presentMainWindow()
    }

    /// Brings the main window forward, re-creating it when it was closed.
    /// On a cold launch before the window exists this only activates the
    /// app; the window appears on its own and picks up the parked request.
    func presentMainWindow() {
        NSApp.activate()
        if isMainWindowMounted,
           let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openMainWindowAction {
            openMainWindowAction(id: "main")
        }
    }

    // MARK: - Helpers

    private func captureLinksAllowed() -> Bool {
        guard EntryPointSettings.bool(EntryPointSettings.allowCaptureLinksKey) else {
            fail("Recording and dictation links are turned off in Settings → Links & Handoff.")
            return false
        }
        return true
    }

    private func fail(_ message: String) {
        Log.app.error("\(message, privacy: .private)")
        AppState.shared.report(message)
        presentMainWindow()
    }
}

extension Notification.Name {
    /// Router → main window: open the command bar (the query is taken from
    /// `ScribeEntryRouter.takePendingSearchQuery()`).
    static let scribeOpenCommandBar = Notification.Name("scribe.openCommandBar")
}
