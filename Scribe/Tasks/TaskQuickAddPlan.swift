import Foundation

/// Everything needed to create a task from the iOS quick-add sheet: the
/// `QuickAddParser` result resolved against the projects and the list the
/// sheet was opened from. Pure, so the Mac's quick-add rules are kept in one
/// testable place for the iPhone / iPad.
struct TaskQuickAddPlan: Equatable {
    var title: String
    var notes: String
    var projectId: String?
    var areaId: String?
    var headingId: String?
    var priority: TodoTask.Priority?
    var dueAt: Date?
    var recurrenceRule: String?
    var tags: [String]
    var startAt: Date?
    var scheduleBucket: TaskScheduleBucket
    var estimatedMinutes: Int?
    /// A typed `+Name` that matches no project (the task stays unfiled).
    var unresolvedProjectName: String?
}

/// One live chip under the quick-add field.
struct TaskQuickAddChip: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case due, start, bucket, priority, project, area, heading, tag, duration, recurrence
    }
    let kind: Kind
    let label: String
    let systemImage: String
    /// Shown in a warning tint (e.g. an unknown project).
    var isWarning: Bool = false

    var id: String { "\(kind.rawValue).\(label)" }
}

enum TaskQuickAddPlanner {

    /// Resolves `parsed` for a task added from `destination` (nil = no list
    /// context, e.g. ⌘N from Today's tab).
    ///
    /// Mirrors the Mac's `TaskListViewModel.commitQuickAdd`: a typed
    /// `+Project` wins, else a project / area list files the task there; the
    /// Someday list parks it; Today plans it for today. Without a typed date
    /// a task is due today unless it's planned another way (Someday, This
    /// Evening, a start date) or added to a container / Someday / Anytime
    /// list, so it isn't silently made due today.
    static func plan(
        parsed: QuickAddParser.ParsedQuickAdd,
        notes: String = "",
        destination: TaskListDestination?,
        headingId: String? = nil,
        projects: [Project],
        calendar: Calendar,
        now: Date
    ) -> TaskQuickAddPlan? {
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        var projectId: String?
        var unresolved: String?
        if let name = parsed.projectName {
            projectId = projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
            if projectId == nil { unresolved = name }
        }

        var areaId: String?
        if projectId == nil, parsed.projectName == nil {
            switch destination {
            case .project(let id)?: projectId = id
            case .area(let id)?:    areaId = id
            default:                break
            }
        }

        // A heading only applies inside its own (destination) project.
        var resolvedHeading: String?
        if let headingId, case .project(let id)? = destination, projectId == id {
            resolvedHeading = headingId
        }

        var tags = parsed.tags
        if case .tag(let tag)? = destination, !tags.contains(tag) { tags.append(tag) }

        var bucket: TaskScheduleBucket = parsed.scheduleBucket ?? .anytime
        if parsed.scheduleBucket == nil, destination == .someday { bucket = .someday }

        let due = parsed.dueAt ?? defaultDueDate(destination: destination, bucket: bucket,
                                                 startAt: parsed.startAt, calendar: calendar, now: now)

        return TaskQuickAddPlan(
            title: title,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            projectId: projectId,
            areaId: areaId,
            headingId: resolvedHeading,
            priority: parsed.priority,
            dueAt: due,
            recurrenceRule: parsed.recurrenceRule,
            tags: tags,
            startAt: parsed.startAt,
            scheduleBucket: bucket,
            estimatedMinutes: parsed.estimatedMinutes,
            unresolvedProjectName: unresolved
        )
    }

    /// Due date for a quick-added task without a typed date (see `plan`).
    static func defaultDueDate(
        destination: TaskListDestination?,
        bucket: TaskScheduleBucket,
        startAt: Date?,
        calendar: Calendar,
        now: Date
    ) -> Date? {
        if bucket == .someday || bucket == .evening || startAt != nil { return nil }
        switch destination {
        case .project?, .area?, .someday?, .anytime?, .logbook?:
            return nil
        case .upcoming?:
            // Adding from Upcoming means "later": tomorrow.
            return TaskListSectioning.startOfTomorrow(now: now, calendar: calendar)
        case .inbox?, .today?, .tag?, .planner?, nil:
            return calendar.startOfDay(for: now)
        }
    }

    // MARK: - Chips

    /// Live chips describing what the current text will create.
    static func chips(
        for plan: TaskQuickAddPlan,
        projects: [Project],
        areas: [TaskArea],
        calendar: Calendar,
        now: Date
    ) -> [TaskQuickAddChip] {
        var out: [TaskQuickAddChip] = []
        if let due = plan.dueAt {
            out.append(TaskQuickAddChip(kind: .due, label: dateLabel(due, calendar: calendar, now: now),
                                        systemImage: "calendar"))
        }
        if let start = plan.startAt {
            out.append(TaskQuickAddChip(kind: .start, label: "Starts " + dateLabel(start, calendar: calendar, now: now),
                                        systemImage: "arrow.right.to.line"))
        }
        if plan.scheduleBucket != .anytime {
            out.append(TaskQuickAddChip(kind: .bucket, label: plan.scheduleBucket.title,
                                        systemImage: plan.scheduleBucket.systemImage))
        }
        if let priority = plan.priority {
            out.append(TaskQuickAddChip(kind: .priority, label: priority.rawValue, systemImage: "flag.fill"))
        }
        if let projectId = plan.projectId, let project = projects.first(where: { $0.id == projectId }) {
            out.append(TaskQuickAddChip(kind: .project, label: project.name, systemImage: project.icon ?? "folder"))
        } else if let unresolved = plan.unresolvedProjectName {
            out.append(TaskQuickAddChip(kind: .project, label: "No project “\(unresolved)”",
                                        systemImage: "folder.badge.questionmark", isWarning: true))
        }
        if let areaId = plan.areaId, let area = areas.first(where: { $0.id == areaId }) {
            out.append(TaskQuickAddChip(kind: .area, label: area.name, systemImage: area.symbol ?? "square.grid.2x2"))
        }
        for tag in plan.tags {
            out.append(TaskQuickAddChip(kind: .tag, label: "#\(tag)", systemImage: "number"))
        }
        if let minutes = plan.estimatedMinutes, minutes > 0 {
            out.append(TaskQuickAddChip(kind: .duration, label: durationLabel(minutes), systemImage: "hourglass"))
        }
        if let raw = plan.recurrenceRule {
            let summary = (try? RecurrenceRule.parse(raw))?.summary ?? raw
            out.append(TaskQuickAddChip(kind: .recurrence, label: summary, systemImage: "repeat"))
        }
        return out
    }

    /// "Today", "Tomorrow", "Today 17:00", else a short date (+ time).
    static func dateLabel(_ date: Date, calendar: Calendar, now: Date) -> String {
        let hasTime = PlannerTimeOfDay.hasTime(date, calendar: calendar)
        var timeStyle = Date.FormatStyle.dateTime.hour().minute()
        timeStyle.calendar = calendar
        timeStyle.timeZone = calendar.timeZone
        let time = hasTime ? " " + date.formatted(timeStyle) : ""
        if calendar.isDate(date, inSameDayAs: now) { return "Today" + time }
        if calendar.isDate(date, inSameDayAs: TaskListSectioning.startOfTomorrow(now: now, calendar: calendar)) {
            return "Tomorrow" + time
        }
        var dayStyle = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        dayStyle.calendar = calendar
        dayStyle.timeZone = calendar.timeZone
        return date.formatted(dayStyle) + time
    }

    /// "~30m" / "~1h" / "~1h 30m".
    static func durationLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "~\(rest)m" }
        if rest == 0 { return "~\(hours)h" }
        return "~\(hours)h \(rest)m"
    }
}
