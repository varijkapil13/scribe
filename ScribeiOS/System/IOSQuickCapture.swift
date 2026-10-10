// ScribeiOS/System/IOSQuickCapture.swift
//
// Quick Capture on iPhone / iPad: a small sheet for jotting down a note or a
// task, opened by the "Quick Capture" App Intent (Action button, Siri,
// Shortcuts) and the Control Center "New Note" / "New Task" controls. The
// intents run in the app process (openAppWhenRun) and post a request here;
// the first active scene presents the sheet (ScribeSystemIntegrationModifier).
// What gets created is planned by the portable ScribeQuickCapturePlan.

import Observation
import SwiftUI

/// One request to show the capture sheet.
struct IOSQuickCaptureRequest: Identifiable, Equatable {
    let id: UUID
    let kind: ScribeQuickCaptureKind

    init(kind: ScribeQuickCaptureKind) {
        self.id = UUID()
        self.kind = kind
    }
}

@MainActor
@Observable
final class IOSQuickCaptureCenter {

    static let shared = IOSQuickCaptureCenter()

    /// The request waiting for a scene to present it.
    private(set) var pending: IOSQuickCaptureRequest?

    private init() {}

    func present(_ kind: ScribeQuickCaptureKind) {
        pending = IOSQuickCaptureRequest(kind: kind)
    }

    /// Hands the pending request to one scene (the first to ask), so iPad
    /// windows don't all open the sheet.
    func claim() -> IOSQuickCaptureRequest? {
        defer { pending = nil }
        return pending
    }
}

/// Entry points the capture intents (ScribeiOS/System/Shared) call in the
/// app process.
@MainActor
enum ScribeiOSCaptureRouting {

    static func presentCapture(_ kind: ScribeCaptureKindAppEnum) {
        IOSQuickCaptureCenter.shared.present(kind == .task ? .task : .note)
    }

    static func startRecordingFromControl() async {
        do {
            _ = try await ScribeIntentsBridge.startRecording()
        } catch {
            Log.app.error("Start Recording control failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Creates what a plan describes.
@MainActor
enum IOSQuickCaptureSaver {

    /// Saves the plan; returns the scribe:// link to the new item.
    static func save(_ plan: ScribeQuickCapturePlan) throws -> URL {
        switch plan {
        case .note(let title, let body):
            let note = try ScribeIntentsData.live.createNote(title: title, body: body)
            return ScribeAppGroup.noteURL(id: note.id)
        case .task(let parsed, let notes):
            let store = TaskStore.shared
            // `+Project` resolves like the Mac's Quick Capture (case-
            // insensitive name match); an unknown name files to the inbox.
            let projectId = try parsed.projectName.flatMap { name in
                try store.fetchProjects().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
            }
            let task = try store.createTask(
                title: parsed.title,
                notes: notes,
                projectId: projectId,
                priority: parsed.priority,
                dueAt: parsed.dueAt,
                recurrenceRule: parsed.recurrenceRule,
                tags: parsed.tags,
                startAt: parsed.startAt,
                scheduleBucket: parsed.scheduleBucket ?? .anytime,
                estimatedMinutes: parsed.estimatedMinutes
            )
            return ScribeAppGroup.taskURL(id: task.id)
        }
    }
}

/// The capture sheet.
struct IOSQuickCaptureSheet: View {

    @State private var kind: ScribeQuickCaptureKind
    @State private var title = ""
    @State private var bodyText = ""
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(kind: ScribeQuickCaptureKind) {
        _kind = State(initialValue: kind)
    }

    private var titlePlaceholder: String { kind == .task ? "Call Sam tomorrow 5pm #work !high" : "Title" }
    private var bodyPlaceholder: String { kind == .task ? "Notes" : "Write something…" }
    private var sheetTitle: String { kind == .task ? "New Task" : "New Note" }

    private var plan: ScribeQuickCapturePlan? {
        ScribeQuickCapturePlan.make(kind: kind, title: title, body: bodyText, now: Date(), calendar: .current)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Capture", selection: $kind) {
                        ForEach(ScribeQuickCaptureKind.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField(titlePlaceholder, text: $title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                    TextField(bodyPlaceholder, text: $bodyText, axis: .vertical)
                        .lineLimit(3...10)
                } footer: {
                    footer
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(plan == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { titleFocused = true }
    }

    @ViewBuilder private var footer: some View {
        if kind == .task, case .task(let parsed, _)? = plan, let due = parsed.dueAt {
            Text("Due \(due.formatted(date: .abbreviated, time: .shortened))")
        } else if kind == .task {
            Text("Type a date, #tag or !priority right in the title.")
        }
    }

    private func save() {
        guard let plan else { return }
        do {
            let link = try IOSQuickCaptureSaver.save(plan)
            let message = kind == .task ? "Task added" : "Note saved"
            IOSSystemIntegration.shared.show(IOSSystemBanner(message: message, link: link))
            dismiss()
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
