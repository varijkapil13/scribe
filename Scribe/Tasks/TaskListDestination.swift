import Foundation

/// A task list the iPhone / iPad app can show: the Things-style smart lists
/// (Inbox, Today, Upcoming, Anytime, Someday, Logbook), the containers (areas,
/// projects, tags) and the day planner.
///
/// Pure and portable (compiled into the macOS SwiftPM target and the iOS app),
/// so list membership and sectioning are unit-tested once and shared by every
/// iOS screen.
enum TaskListDestination: Hashable, Sendable, Identifiable {
    case inbox
    case today
    case upcoming
    case anytime
    case someday
    case logbook
    case area(String)
    case project(String)
    case tag(String)
    /// The day planner time grid (events + scheduled tasks).
    case planner

    /// The smart lists, in sidebar order.
    static let smartLists: [TaskListDestination] = [.inbox, .today, .upcoming, .anytime, .someday, .logbook]

    var id: String {
        switch self {
        case .inbox:            return "inbox"
        case .today:            return "today"
        case .upcoming:         return "upcoming"
        case .anytime:          return "anytime"
        case .someday:          return "someday"
        case .logbook:          return "logbook"
        case .area(let id):     return "area.\(id)"
        case .project(let id):  return "project.\(id)"
        case .tag(let tag):     return "tag.\(tag)"
        case .planner:          return "planner"
        }
    }

    /// Title for the smart lists; containers are named by their row (the
    /// caller resolves the project / area name).
    var fixedTitle: String? {
        switch self {
        case .inbox:          return "Inbox"
        case .today:          return "Today"
        case .upcoming:       return "Upcoming"
        case .anytime:        return "Anytime"
        case .someday:        return "Someday"
        case .logbook:        return "Logbook"
        case .planner:        return "Planner"
        case .tag(let tag):   return "#\(tag)"
        case .area, .project: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .inbox:    return "tray"
        case .today:    return "star"
        case .upcoming: return "calendar"
        case .anytime:  return "square.stack"
        case .someday:  return "archivebox"
        case .logbook:  return "book.closed"
        case .area:     return "square.grid.2x2"
        case .project:  return "folder"
        case .tag:      return "number"
        case .planner:  return "calendar.day.timeline.left"
        }
    }

    /// The store query backing the list. Upcoming / Anytime / Planner read
    /// every open task and narrow it with `includes(_:now:calendar:)`
    /// (the store's `.upcoming` filter stops at a 7-day window).
    var storeFilter: TaskStore.Filter {
        switch self {
        case .inbox:            return .inbox
        case .today:            return .today
        case .upcoming:         return .all
        case .anytime:          return .all
        case .someday:          return .someday
        case .logbook:          return .completed
        case .area(let id):     return .area(id)
        case .project(let id):  return .project(id)
        case .tag(let tag):     return .tag(tag)
        case .planner:          return .all
        }
    }

    /// Client-side membership on top of `storeFilter`.
    func includes(_ task: TodoTask, now: Date, calendar: Calendar) -> Bool {
        switch self {
        case .upcoming:
            return TaskListSectioning.upcomingDate(of: task, now: now, calendar: calendar) != nil
        case .anytime:
            // Everything available now that isn't parked: Today work included,
            // deferred and Someday tasks left out.
            return TaskPlanningRules.isActive(task)
                && task.scheduleBucket != .someday
                && !TaskPlanningRules.isDeferred(task, now: now, calendar: calendar)
        case .inbox, .today, .someday, .logbook, .area, .project, .tag, .planner:
            return true
        }
    }

    /// Whether the list's rows can be manually reordered (one sortOrder
    /// scope, or a scope per project).
    var supportsManualOrder: Bool {
        switch self {
        case .inbox, .project, .area, .anytime, .someday, .tag, .today: return true
        case .upcoming, .logbook, .planner: return false
        }
    }

    /// Whether a task dragged onto the list's sidebar row can be filed there.
    var acceptsDrops: Bool {
        switch self {
        case .inbox, .today, .anytime, .someday, .logbook, .area, .project: return true
        case .upcoming, .tag, .planner: return false
        }
    }
}

// MARK: - Sections

/// One titled group of rows in an iOS task list.
struct TaskListSection: Identifiable, Equatable {

    /// What the section stands for; drives what dropping a task on it does.
    enum Kind: Hashable {
        case overdue
        case today
        case evening
        /// One calendar day (start of day) in Upcoming.
        case day(Date)
        /// A later month (start of the month) in Upcoming.
        case month(Date)
        /// Tasks of a project (nil = no project) in Anytime / Someday / Area.
        case project(String?)
        /// Loose tasks filed directly under an area.
        case areaTasks(String)
        /// Tasks of a project not filed under a heading.
        case noHeading
        case heading(ProjectHeading)
        /// Completed / cancelled on one day (start of day), Logbook.
        case finishedDay(Date)
        /// A single ungrouped list (Inbox, tags).
        case plain
    }

    let kind: Kind
    let title: String
    var tasks: [TodoTask]

    var id: String {
        switch kind {
        case .overdue:                 return "overdue"
        case .today:                   return "today"
        case .evening:                 return "evening"
        case .day(let day):            return "day.\(Int(day.timeIntervalSince1970))"
        case .month(let month):        return "month.\(Int(month.timeIntervalSince1970))"
        case .project(let id):         return "project.\(id ?? "none")"
        case .areaTasks(let id):       return "area.\(id)"
        case .noHeading:               return "noHeading"
        case .heading(let heading):    return "heading.\(heading.id)"
        case .finishedDay(let day):    return "finished.\(Int(day.timeIntervalSince1970))"
        case .plain:                   return "plain"
        }
    }
}

/// Pure sectioning, filtering and ordering helpers for the iOS task lists.
enum TaskListSectioning {

    /// Builds the sections for `destination` from tasks already fetched with
    /// its `storeFilter` (in store order). Empty sections are dropped, except
    /// project headings (kept so a task can be dragged under them).
    static func sections(
        for destination: TaskListDestination,
        tasks: [TodoTask],
        headings: [ProjectHeading] = [],
        projects: [Project] = [],
        calendar: Calendar,
        now: Date
    ) -> [TaskListSection] {
        let visible = tasks.filter { destination.includes($0, now: now, calendar: calendar) }
        switch destination {
        case .today:
            return todaySections(visible, calendar: calendar, now: now)
        case .upcoming:
            return upcomingSections(visible, calendar: calendar, now: now)
        case .anytime, .someday:
            return projectSections(visible, projects: projects, leadingTitle: "No Project")
        case .logbook:
            return logbookSections(visible, calendar: calendar, now: now)
        case .area(let areaId):
            let loose = visible.filter { $0.projectId == nil }
            var out: [TaskListSection] = []
            if !loose.isEmpty { out.append(TaskListSection(kind: .areaTasks(areaId), title: "Tasks", tasks: loose)) }
            let areaProjects = projects.filter { $0.areaId == areaId }
            let inProjects = visible.filter { $0.projectId != nil }
            out += projectSections(inProjects, projects: areaProjects, leadingTitle: nil)
            return out
        case .project:
            return headingSections(visible, headings: headings)
        case .inbox, .tag:
            return visible.isEmpty ? [] : [TaskListSection(kind: .plain, title: "", tasks: visible)]
        case .planner:
            return []
        }
    }

    // MARK: Today

    /// Overdue / Today / This Evening, mirroring `TaskPlanningRules`.
    static func todaySections(_ tasks: [TodoTask], calendar: Calendar, now: Date) -> [TaskListSection] {
        let startOfToday = calendar.startOfDay(for: now)
        var overdue: [TodoTask] = []
        var today: [TodoTask] = []
        var evening: [TodoTask] = []
        for task in tasks where TaskPlanningRules.isInToday(task, now: now, calendar: calendar) {
            if let due = task.dueAt, due < startOfToday {
                overdue.append(task)
            } else if TaskPlanningRules.isInEvening(task, now: now, calendar: calendar) {
                evening.append(task)
            } else {
                today.append(task)
            }
        }
        var out: [TaskListSection] = []
        if !overdue.isEmpty { out.append(TaskListSection(kind: .overdue, title: "Overdue", tasks: overdue)) }
        if !today.isEmpty { out.append(TaskListSection(kind: .today, title: "Today", tasks: today)) }
        if !evening.isEmpty { out.append(TaskListSection(kind: .evening, title: "This Evening", tasks: evening)) }
        return out
    }

    // MARK: Upcoming

    /// How many single days Upcoming lists before switching to months.
    static let upcomingDayCount = 7

    /// The day an open task is listed on in Upcoming (tomorrow onward), or nil
    /// when it isn't upcoming. A task deferred to a later start is listed on
    /// its start day; otherwise on its due day.
    static func upcomingDate(of task: TodoTask, now: Date, calendar: Calendar) -> Date? {
        guard TaskPlanningRules.isActive(task) else { return nil }
        let tomorrow = startOfTomorrow(now: now, calendar: calendar)
        if let start = task.startAt, start >= tomorrow {
            return calendar.startOfDay(for: start)
        }
        if let due = task.dueAt, due >= tomorrow {
            return calendar.startOfDay(for: due)
        }
        return nil
    }

    /// One section per day for the next `upcomingDayCount` days (non-empty
    /// ones), then one per later month.
    static func upcomingSections(_ tasks: [TodoTask], calendar: Calendar, now: Date) -> [TaskListSection] {
        let tomorrow = startOfTomorrow(now: now, calendar: calendar)
        let endOfDays = calendar.date(byAdding: .day, value: upcomingDayCount, to: tomorrow)
            ?? tomorrow.addingTimeInterval(TimeInterval(upcomingDayCount) * 86_400)

        var byDay: [Date: [TodoTask]] = [:]
        var byMonth: [Date: [TodoTask]] = [:]
        for task in tasks {
            guard let day = upcomingDate(of: task, now: now, calendar: calendar) else { continue }
            if day < endOfDays {
                byDay[day, default: []].append(task)
            } else {
                let month = startOfMonth(day, calendar: calendar)
                byMonth[month, default: []].append(task)
            }
        }

        var out: [TaskListSection] = []
        for day in byDay.keys.sorted() {
            let rows = sortedByListedDate(byDay[day] ?? [], now: now, calendar: calendar)
            out.append(TaskListSection(kind: .day(day), title: dayTitle(day, now: now, calendar: calendar), tasks: rows))
        }
        for month in byMonth.keys.sorted() {
            let rows = sortedByListedDate(byMonth[month] ?? [], now: now, calendar: calendar)
            out.append(TaskListSection(kind: .month(month), title: monthTitle(month, calendar: calendar), tasks: rows))
        }
        return out
    }

    private static func sortedByListedDate(_ tasks: [TodoTask], now: Date, calendar: Calendar) -> [TodoTask] {
        tasks.enumerated().sorted { a, b in
            let da = upcomingDate(of: a.element, now: now, calendar: calendar) ?? .distantFuture
            let db = upcomingDate(of: b.element, now: now, calendar: calendar) ?? .distantFuture
            if da != db { return da < db }
            return a.offset < b.offset
        }
        .map(\.element)
    }

    /// "Tomorrow", else e.g. "Monday, Oct 12".
    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        let tomorrow = startOfTomorrow(now: now, calendar: calendar)
        if calendar.isDate(day, inSameDayAs: tomorrow) { return "Tomorrow" }
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    static func monthTitle(_ month: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return month.formatted(style)
    }

    // MARK: Containers

    /// Tasks grouped by project: project-less ones first (titled
    /// `leadingTitle`, or skipped when nil), then `projects` in order. Tasks
    /// of projects not in `projects` join the leading group.
    static func projectSections(
        _ tasks: [TodoTask],
        projects: [Project],
        leadingTitle: String?
    ) -> [TaskListSection] {
        let known = Set(projects.map(\.id))
        var loose: [TodoTask] = []
        var byProject: [String: [TodoTask]] = [:]
        for task in tasks {
            if let projectId = task.projectId, known.contains(projectId) {
                byProject[projectId, default: []].append(task)
            } else {
                loose.append(task)
            }
        }
        var out: [TaskListSection] = []
        if let leadingTitle, !loose.isEmpty {
            out.append(TaskListSection(kind: .project(nil), title: leadingTitle, tasks: loose))
        }
        for project in projects {
            guard let rows = byProject[project.id], !rows.isEmpty else { continue }
            out.append(TaskListSection(kind: .project(project.id), title: project.name, tasks: rows))
        }
        return out
    }

    /// A project's tasks: those under no heading first, then one section per
    /// heading in order (empty headings kept as drop targets).
    static func headingSections(_ tasks: [TodoTask], headings: [ProjectHeading]) -> [TaskListSection] {
        let headingIds = Set(headings.map(\.id))
        var loose: [TodoTask] = []
        var byHeading: [String: [TodoTask]] = [:]
        for task in tasks {
            if let headingId = task.headingId, headingIds.contains(headingId) {
                byHeading[headingId, default: []].append(task)
            } else {
                loose.append(task)
            }
        }
        var out: [TaskListSection] = []
        if !loose.isEmpty { out.append(TaskListSection(kind: .noHeading, title: "", tasks: loose)) }
        for heading in headings.sorted(by: { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.id < $1.id }) {
            let title = heading.title.isEmpty ? "Untitled Heading" : heading.title
            out.append(TaskListSection(kind: .heading(heading), title: title, tasks: byHeading[heading.id] ?? []))
        }
        return out
    }

    // MARK: Logbook

    /// Finished tasks grouped by the day they were completed / cancelled,
    /// newest first.
    static func logbookSections(_ tasks: [TodoTask], calendar: Calendar, now: Date) -> [TaskListSection] {
        var byDay: [Date: [TodoTask]] = [:]
        for task in tasks {
            guard let finished = task.completedAt ?? task.cancelledAt else { continue }
            byDay[calendar.startOfDay(for: finished), default: []].append(task)
        }
        return byDay.keys.sorted(by: >).map { day in
            let rows = (byDay[day] ?? []).sorted { a, b in
                let fa = a.completedAt ?? a.cancelledAt ?? .distantPast
                let fb = b.completedAt ?? b.cancelledAt ?? .distantPast
                return fa != fb ? fa > fb : a.id < b.id
            }
            return TaskListSection(kind: .finishedDay(day), title: finishedDayTitle(day, now: now, calendar: calendar), tasks: rows)
        }
    }

    static func finishedDayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    // MARK: Tag filter

    /// Tasks carrying every tag in `required` (all tasks when it's empty).
    static func filter(_ tasks: [TodoTask], requiringTags required: Set<String>, tagsByTask: [String: [String]]) -> [TodoTask] {
        guard !required.isEmpty else { return tasks }
        return tasks.filter { task in
            required.isSubset(of: Set(tagsByTask[task.id] ?? []))
        }
    }

    // MARK: Counts

    /// Sidebar count for a smart list over every task (open ones counted).
    /// Nil for lists that show no count.
    static func count(for destination: TaskListDestination, in tasks: [TodoTask], now: Date, calendar: Calendar) -> Int? {
        switch destination {
        case .inbox:
            return tasks.filter(TaskPlanningRules.isInInbox).count
        case .today:
            return tasks.filter { TaskPlanningRules.isInToday($0, now: now, calendar: calendar) }.count
        case .upcoming, .anytime, .someday, .logbook, .area, .project, .tag, .planner:
            return nil
        }
    }

    /// Overdue tasks among `tasks` (open, due before today).
    static func overdueCount(in tasks: [TodoTask], now: Date, calendar: Calendar) -> Int {
        let startOfToday = calendar.startOfDay(for: now)
        return tasks.filter { task in
            guard TaskPlanningRules.isActive(task), let due = task.dueAt else { return false }
            return due < startOfToday && !TaskPlanningRules.isDeferred(task, now: now, calendar: calendar)
        }.count
    }

    /// The app icon badge: open tasks in Today (overdue included).
    static func appBadgeCount(_ tasks: [TodoTask], now: Date, calendar: Calendar) -> Int {
        tasks.filter { TaskPlanningRules.isInToday($0, now: now, calendar: calendar) }.count
    }

    // MARK: Reordering

    /// `ids` with the rows at `source` moved before index `destination`
    /// (SwiftUI `onMove` semantics: `destination` indexes the original array).
    static func reordered(_ ids: [String], moving source: IndexSet, to destination: Int) -> [String] {
        let valid = source.filter { $0 >= 0 && $0 < ids.count }
        guard !valid.isEmpty else { return ids }
        let moving = valid.map { ids[$0] }
        var remaining: [String] = []
        for (index, id) in ids.enumerated() where !valid.contains(index) {
            remaining.append(id)
        }
        let clamped = min(max(destination, 0), ids.count)
        let shift = valid.filter { $0 < clamped }.count
        let insertAt = min(max(clamped - shift, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        return remaining
    }

    /// Splits a new display order into per-project scopes (sortOrder is per
    /// project), keeping each scope's relative order. Key nil = Inbox scope.
    static func orderScopes(_ orderedIds: [String], tasks: [TodoTask]) -> [(projectId: String?, ids: [String])] {
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String?] = []
        var groups: [String: [String]] = [:]
        let inboxKey = "\u{0}inbox"
        for id in orderedIds {
            guard let task = byId[id] else { continue }
            let key = task.projectId ?? inboxKey
            if groups[key] == nil { order.append(task.projectId) }
            groups[key, default: []].append(id)
        }
        return order.map { projectId in (projectId: projectId, ids: groups[projectId ?? inboxKey] ?? []) }
    }

    // MARK: Helpers

    static func startOfTomorrow(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    static func startOfMonth(_ date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? calendar.startOfDay(for: date)
    }
}

// MARK: - Drag token

/// In-app drag payload for a task row / card: a plain string, so it works with
/// SwiftUI's `draggable` / `dropDestination(for: String.self)` without
/// registering a custom UTI.
enum TaskDragToken {
    static let prefix = "scribe-task:"

    static func encode(_ taskId: String) -> String { prefix + taskId }

    /// The task id in `token`, or nil for any other dragged string.
    static func decode(_ token: String) -> String? {
        guard token.hasPrefix(prefix) else { return nil }
        let id = String(token.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}
