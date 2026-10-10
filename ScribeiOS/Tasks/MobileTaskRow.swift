import SwiftUI

/// One task row: completion circle, title, and a metadata line (when-plan,
/// dates, duration, project, tags, checklist progress, repeat, reminder).
struct MobileTaskRow: View {
    let task: TodoTask
    var projectName: String?
    var tags: [String] = []
    var subtaskProgress: SubtaskProgress?
    /// Hide the project label (inside that project's own list).
    var showsProject: Bool = true
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: checkboxSymbol)
                    .font(.title3)
                    .foregroundStyle(checkboxColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark as not done" : "Complete")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if task.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    Text(task.title.isEmpty ? "Untitled task" : task.title)
                        .strikethrough(task.isCompleted || task.isCancelled)
                        .foregroundStyle(task.isCompleted || task.isCancelled ? .secondary : .primary)
                        .lineLimit(3)
                }
                if hasMeta { meta }
            }
            Spacer(minLength: 0)
            if let priority = task.priority, !task.isCompleted {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(TasksColor.priority(priority))
                    .accessibilityLabel("\(priority.rawValue) priority")
            }
        }
        .contentShape(Rectangle())
    }

    private var checkboxSymbol: String {
        if task.isCancelled { return "xmark.circle" }
        if task.isCompleted { return "checkmark.circle.fill" }
        return "circle"
    }

    private var checkboxColor: Color {
        if task.isCompleted { return .accentColor }
        if let priority = task.priority { return TasksColor.priority(priority) }
        return .secondary
    }

    private var hasMeta: Bool {
        task.dueAt != nil || task.startAt != nil || task.scheduleBucket != .anytime
            || (task.estimatedMinutes ?? 0) > 0 || (showsProject && projectName != nil)
            || !tags.isEmpty || (subtaskProgress?.total ?? 0) > 0
            || task.recurrenceRule != nil || task.remindAt != nil || !task.notes.isEmpty
    }

    private var meta: some View {
        HStack(spacing: 8) {
            if task.scheduleBucket == .evening || task.scheduleBucket == .someday {
                Image(systemName: task.scheduleBucket.systemImage)
                    .foregroundStyle(task.scheduleBucket == .evening ? Color.indigo : Color.secondary)
            }
            if let due = task.dueAt {
                Label(dueText(due), systemImage: "calendar")
                    .foregroundStyle(isOverdue(due) ? Color.red : Color.secondary)
            }
            if let start = task.startAt, start > Date() {
                Label(start.formatted(.dateTime.month(.abbreviated).day()), systemImage: "arrow.right.to.line")
            }
            if let minutes = task.estimatedMinutes, minutes > 0 {
                Text(TaskQuickAddPlanner.durationLabel(minutes))
            }
            if task.recurrenceRule != nil {
                Image(systemName: "repeat")
            }
            if task.remindAt != nil {
                Image(systemName: "bell")
            }
            if let progress = subtaskProgress, progress.total > 0 {
                Label("\(progress.completed)/\(progress.total)", systemImage: "checklist")
            }
            if !task.notes.isEmpty {
                Image(systemName: "note.text")
            }
            if showsProject, let projectName {
                Label(projectName, systemImage: "folder")
            }
            if !tags.isEmpty {
                Text(tags.map { "#\($0)" }.joined(separator: " "))
                    .foregroundStyle(.tint)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(CompactMetaLabelStyle())
        .lineLimit(1)
    }

    private func isOverdue(_ due: Date) -> Bool {
        !task.isCompleted && due < Calendar.current.startOfDay(for: Date())
    }

    private func dueText(_ due: Date) -> String {
        TaskQuickAddPlanner.dateLabel(due, calendar: .current, now: Date())
    }
}

/// Icon + text tightly spaced, for row metadata.
private struct CompactMetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Shared row menus

/// Context-menu items for a task row / card / planner block.
struct TaskRowContextMenu: View {
    let task: TodoTask
    let projects: [Project]
    var headings: [ProjectHeading] = []
    var onOpen: (() -> Void)?
    let actions: TaskMobileActions

    var body: some View {
        if let onOpen {
            Button(action: onOpen) { Label("Open", systemImage: "arrow.up.forward.square") }
        }
        Button { actions.toggleCompleted(task) } label: {
            Label(task.isCompleted ? "Mark as Not Done" : "Complete",
                  systemImage: task.isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle")
        }

        Menu {
            ForEach([TaskScheduleBucket.today, .evening, .anytime, .someday], id: \.self) { bucket in
                Button { actions.plan(task, bucket: bucket) } label: {
                    Label(bucket.title, systemImage: task.scheduleBucket == bucket ? "checkmark" : bucket.systemImage)
                }
            }
        } label: { Label("When", systemImage: "moon.stars") }

        Menu {
            Button { actions.setDue(TaskQuickDates.today(), for: task) } label: { Label("Today", systemImage: "sun.max") }
            Button { actions.setDue(TaskQuickDates.tomorrow(), for: task) } label: { Label("Tomorrow", systemImage: "sunrise") }
            Button { actions.setDue(TaskQuickDates.nextWeek(), for: task) } label: { Label("Next Week", systemImage: "calendar.badge.plus") }
            Divider()
            Button(role: .destructive) { actions.setDue(nil, for: task) } label: { Label("No Due Date", systemImage: "calendar.badge.minus") }
        } label: { Label("Due", systemImage: "calendar") }

        Menu {
            ForEach(TodoTask.Priority.allCases, id: \.self) { priority in
                Button { actions.setPriority(priority, for: task) } label: {
                    Label(priority.rawValue, systemImage: task.priority == priority ? "checkmark" : "flag")
                }
            }
            Button { actions.setPriority(nil, for: task) } label: {
                Label("None", systemImage: task.priority == nil ? "checkmark" : "flag.slash")
            }
        } label: { Label("Priority", systemImage: "flag") }

        Menu {
            Button { actions.move(task, toProject: nil) } label: {
                Label("Inbox", systemImage: task.projectId == nil ? "checkmark" : "tray")
            }
            ForEach(projects) { project in
                Button { actions.move(task, toProject: project.id) } label: {
                    Label(project.name, systemImage: task.projectId == project.id ? "checkmark" : (project.icon ?? "folder"))
                }
            }
        } label: { Label("Move to Project", systemImage: "folder") }

        if task.projectId != nil, !headings.isEmpty {
            Menu {
                Button { actions.setHeading(nil, for: task) } label: {
                    Label("No Heading", systemImage: task.headingId == nil ? "checkmark" : "minus")
                }
                ForEach(headings) { heading in
                    Button { actions.setHeading(heading.id, for: task) } label: {
                        Label(heading.title, systemImage: task.headingId == heading.id ? "checkmark" : "text.line.first.and.arrowtriangle.forward")
                    }
                }
            } label: { Label("Heading", systemImage: "list.bullet.indent") }
        }

        Button { actions.togglePinned(task) } label: {
            Label(task.isPinned ? "Unpin" : "Pin", systemImage: task.isPinned ? "pin.slash" : "pin")
        }
        Button { actions.toggleCancelled(task) } label: {
            Label(task.isCancelled ? "Reopen" : "Won’t Do", systemImage: task.isCancelled ? "arrow.uturn.backward" : "xmark.circle")
        }
        Divider()
        Button(role: .destructive) { actions.delete(task) } label: { Label("Delete", systemImage: "trash") }
    }
}

extension View {
    /// Leading: complete. Trailing: delete, Someday, This Evening, Today.
    func taskSwipeActions(_ task: TodoTask, actions: TaskMobileActions) -> some View {
        self
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { actions.toggleCompleted(task) } label: {
                    Label(task.isCompleted ? "Undo" : "Done", systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(.green)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { actions.delete(task) } label: { Label("Delete", systemImage: "trash") }
                Button { actions.plan(task, bucket: .someday) } label: { Label("Someday", systemImage: "archivebox") }
                    .tint(.brown)
                Button { actions.plan(task, bucket: .evening) } label: { Label("Evening", systemImage: "moon") }
                    .tint(.indigo)
                Button { actions.plan(task, bucket: .today) } label: { Label("Today", systemImage: "star") }
                    .tint(.yellow)
            }
    }
}
