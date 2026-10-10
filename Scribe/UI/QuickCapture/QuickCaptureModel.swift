import Foundation
import SwiftUI

/// State behind the Quick Capture panel: the text, the mode, the live task
/// preview, dictation, and saving. The decisions themselves live in
/// `QuickCaptureComposer` / `QuickCaptureSaver`; this wires them to the UI.
@MainActor
final class QuickCaptureModel: ObservableObject {

    @Published var text: String = ""
    @Published var mode: QuickCaptureMode {
        didSet { defaults.set(mode.rawValue, forKey: QuickCaptureMode.defaultsKey) }
    }
    /// Shown under the field when a save fails.
    @Published var errorMessage: String?
    /// Existing project names, refreshed each time the panel opens, so the
    /// `+Project` chip can say when a task will land in the Inbox instead.
    @Published private(set) var knownProjects: [String]?
    /// Bumped each time the panel opens; the view focuses the field on change.
    @Published private(set) var focusToken: Int = 0
    @Published private(set) var isSaving = false

    let dictation: QuickCaptureDictation

    /// Called after a successful save with the outcome and whether the user
    /// asked to open it in the main window (⌘Return).
    var onSaved: ((QuickCaptureSaveOutcome, Bool) -> Void)?
    /// Called when the user dismisses the panel (Esc).
    var onCancel: (() -> Void)?
    /// The SwiftUI `openWindow` action, captured from the hosted view so the
    /// controller can reopen the main window after it was closed.
    var openWindowAction: OpenWindowAction?

    private let defaults: UserDefaults
    private var textBeforeDictation = ""

    /// Dictation is off under UI tests (no audio stack in the test host).
    let isDictationAvailable: Bool

    init(defaults: UserDefaults, isDictationAvailable: Bool) {
        self.defaults = defaults
        self.isDictationAvailable = isDictationAvailable
        self.dictation = QuickCaptureDictation()
        self.mode = QuickCaptureMode.restored(from: defaults.string(forKey: QuickCaptureMode.defaultsKey))
        dictation.onLiveText = { [weak self] live in
            self?.applyDictated(live)
        }
    }

    // MARK: - Derived

    /// Preview chips for the task line (empty outside Task mode).
    var chips: [QuickCaptureChip] {
        guard mode == .task else { return [] }
        let firstLine = QuickCaptureComposer.splitFirstLine(text).first
        guard !firstLine.isEmpty else { return [] }
        let parsed = QuickAddParser.parse(firstLine)
        return QuickCaptureComposer.chips(
            for: parsed,
            knownProjects: knownProjects,
            now: Date(),
            calendar: Calendar.current
        )
    }

    /// The task title as it will be saved (metadata stripped), for the
    /// preview line. Nil outside Task mode or when it equals the input.
    var taskTitlePreview: String? {
        guard mode == .task else { return nil }
        let firstLine = QuickCaptureComposer.splitFirstLine(text).first
        guard !firstLine.isEmpty else { return nil }
        let title = QuickAddParser.parse(firstLine).title
        return title == firstLine ? nil : title
    }

    var canSave: Bool {
        !isSaving && QuickCaptureComposer.canSave(mode: mode, text: text, parse: { QuickAddParser.parse($0) })
    }

    // MARK: - Lifecycle

    /// Refreshes per-open state. Keeps an unsaved draft from last time.
    func prepareForShow() {
        errorMessage = nil
        knownProjects = (try? TaskStore.shared.fetchProjects())?.map(\.name)
        focusToken &+= 1
    }

    /// Esc: stop dictation (text already streamed into the field stays as a
    /// draft) and dismiss.
    func cancel() {
        dictation.cancel()
        onCancel?()
    }

    func select(_ newMode: QuickCaptureMode) {
        mode = newMode
        errorMessage = nil
    }

    // MARK: - Dictation

    func toggleDictation() {
        guard isDictationAvailable else { return }
        if dictation.isActive {
            Task { await self.finishDictation() }
        } else {
            textBeforeDictation = text
            dictation.start()
        }
    }

    private func finishDictation() async {
        let heard = await dictation.stop()
        text = QuickCaptureComposer.merging(typed: textBeforeDictation, dictated: heard)
    }

    private func applyDictated(_ live: String) {
        guard dictation.isActive else { return }
        text = QuickCaptureComposer.merging(typed: textBeforeDictation, dictated: live)
    }

    // MARK: - Save

    /// Return saves; ⌘Return saves and opens the result in the main window.
    func save(openAfter: Bool) {
        guard !isSaving else { return }
        isSaving = true
        Task { await self.performSave(openAfter: openAfter) }
    }

    private func performSave(openAfter: Bool) async {
        defer { isSaving = false }
        if dictation.isActive {
            await finishDictation()
        }
        guard let request = QuickCaptureComposer.request(
            mode: mode,
            text: text,
            parse: { QuickAddParser.parse($0) }
        ) else { return }

        let saver = QuickCaptureSaver(noteStore: NoteStore.shared, taskStore: TaskStore.shared)
        do {
            let outcome = try saver.save(request, now: Date(), timeZone: TimeZone.current)
            text = ""
            errorMessage = nil
            onSaved?(outcome, openAfter)
        } catch {
            Log.ui.error("Quick Capture save failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
