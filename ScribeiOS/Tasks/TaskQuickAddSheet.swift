import SwiftUI

/// Quick-add sheet: one natural-language line (`QuickAddParser` +
/// `QuickAddPlanningParser`: dates, "every …", "starting …", someday /
/// tonight, `~30m`, `#tag`, `+Project`, `!priority`) with live chips showing
/// what will be created, plus optional notes.
struct TaskQuickAddSheet: View {
    /// The list the sheet was opened from (files / plans the task there).
    let destination: TaskListDestination?
    var headingId: String?
    @ObservedObject var library: TasksLibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var notes = ""
    @State private var addAnother = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    private var plan: TaskQuickAddPlan? {
        let parsed = QuickAddParser.parse(text)
        return TaskQuickAddPlanner.plan(parsed: parsed, notes: notes, destination: destination,
                                        headingId: headingId, projects: library.projects,
                                        calendar: .current, now: Date())
    }

    var body: some View {
        let current = plan
        NavigationStack {
            Form {
                Section {
                    TextField("New task", text: $text, axis: .vertical)
                        .font(.title3)
                        .lineLimit(1...4)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                    if let current {
                        chips(for: current)
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(1...6)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Try “call Sam tomorrow 4pm +Work #phone !high ~15m”, “water plants every 2 weeks after completion”, or “read book someday”.")
                }
                if let context = contextTitle {
                    Section {
                        Label(context, systemImage: destination.map { library.systemImage(for: $0) } ?? "tray")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                Section {
                    Toggle("Add another after this one", isOn: $addAnother)
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(current == nil)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .onAppear {
                library.start()
                titleFocused = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var contextTitle: String? {
        guard let destination else { return nil }
        switch destination {
        case .project, .area, .someday, .tag, .today, .upcoming:
            return "Adding to \(library.title(for: destination))"
        case .inbox, .anytime, .logbook, .planner:
            return nil
        }
    }

    private var emptyChipText: String {
        let list = destination.map { library.title(for: $0) } ?? "Inbox"
        return "No date or project — added to \(list)"
    }

    private func chips(for current: TaskQuickAddPlan) -> some View {
        let items = TaskQuickAddPlanner.chips(for: current, projects: library.projects, areas: library.areas,
                                              calendar: .current, now: Date())
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if items.isEmpty {
                    Text(emptyChipText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { chip in
                    Label(chip.label, systemImage: chip.systemImage)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(chip.isWarning ? Color.orange : Color.accentColor)
                        .background(Capsule().fill((chip.isWarning ? Color.orange : Color.accentColor).opacity(0.14)))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func add() {
        guard let current = plan else { return }
        do {
            _ = try TaskStore.shared.createTask(
                title: current.title,
                notes: current.notes,
                projectId: current.projectId,
                priority: current.priority,
                dueAt: current.dueAt,
                recurrenceRule: current.recurrenceRule,
                tags: current.tags,
                startAt: current.startAt,
                scheduleBucket: current.scheduleBucket,
                estimatedMinutes: current.estimatedMinutes,
                areaId: current.areaId,
                headingId: current.headingId
            )
            errorMessage = nil
            if addAnother {
                text = ""
                notes = ""
                titleFocused = true
            } else {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
