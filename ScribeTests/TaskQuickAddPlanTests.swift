import XCTest
@testable import Scribe

/// The iOS quick-add sheet's resolution of parsed text against projects and
/// the list it was opened from, and its live chips.
final class TaskQuickAddPlanTests: XCTestCase {

    private static let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private var cal: Calendar { Self.cal }
    private var now: Date { date(11, 10) }

    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour)) ?? Date(timeIntervalSince1970: 0)
    }

    private let projects = [Project(id: "p1", name: "Work", icon: "briefcase"), Project(id: "p2", name: "Home")]

    private func parsed(_ title: String,
                        tags: [String] = [],
                        priority: TodoTask.Priority? = nil,
                        project: String? = nil,
                        due: Date? = nil,
                        rule: String? = nil,
                        startAt: Date? = nil,
                        bucket: TaskScheduleBucket? = nil,
                        minutes: Int? = nil) -> QuickAddParser.ParsedQuickAdd {
        QuickAddParser.ParsedQuickAdd(title: title, tags: tags, priority: priority, projectName: project,
                                      dueAt: due, recurrenceRule: rule, startAt: startAt,
                                      scheduleBucket: bucket, estimatedMinutes: minutes)
    }

    private func plan(_ input: QuickAddParser.ParsedQuickAdd,
                      in destination: TaskListDestination?,
                      headingId: String? = nil) -> TaskQuickAddPlan? {
        TaskQuickAddPlanner.plan(parsed: input, destination: destination, headingId: headingId,
                                 projects: projects, calendar: cal, now: now)
    }

    func testEmptyTitleMakesNothing() {
        XCTAssertNil(plan(parsed("   "), in: .inbox))
    }

    func testTypedProjectWinsCaseInsensitively() throws {
        let result = try XCTUnwrap(plan(parsed("call", project: "work"), in: .project("p2")))
        XCTAssertEqual(result.projectId, "p1")
        XCTAssertNil(result.unresolvedProjectName)
    }

    func testUnknownProjectStaysUnfiledAndIsReported() throws {
        let result = try XCTUnwrap(plan(parsed("call", project: "Nope"), in: .project("p2")))
        XCTAssertNil(result.projectId)
        XCTAssertEqual(result.unresolvedProjectName, "Nope")
    }

    func testContainerListsFileTheTaskWithoutADueDate() throws {
        let inProject = try XCTUnwrap(plan(parsed("a"), in: .project("p2"), headingId: "h"))
        XCTAssertEqual(inProject.projectId, "p2")
        XCTAssertEqual(inProject.headingId, "h")
        XCTAssertNil(inProject.dueAt)

        let inArea = try XCTUnwrap(plan(parsed("a"), in: .area("a1")))
        XCTAssertEqual(inArea.areaId, "a1")
        XCTAssertNil(inArea.projectId)
        XCTAssertNil(inArea.dueAt)
    }

    func testHeadingIgnoredOutsideItsProject() throws {
        let result = try XCTUnwrap(plan(parsed("a", project: "Work"), in: .project("p2"), headingId: "h"))
        XCTAssertNil(result.headingId)
    }

    func testDefaultDueDates() throws {
        XCTAssertEqual(try XCTUnwrap(plan(parsed("a"), in: .inbox)).dueAt, date(11))
        XCTAssertEqual(try XCTUnwrap(plan(parsed("a"), in: .today)).dueAt, date(11))
        XCTAssertEqual(try XCTUnwrap(plan(parsed("a"), in: nil)).dueAt, date(11))
        XCTAssertEqual(try XCTUnwrap(plan(parsed("a"), in: .upcoming)).dueAt, date(12))
        XCTAssertNil(try XCTUnwrap(plan(parsed("a"), in: .anytime)).dueAt)
        XCTAssertNil(try XCTUnwrap(plan(parsed("a", bucket: .evening), in: .today)).dueAt)
        XCTAssertNil(try XCTUnwrap(plan(parsed("a", startAt: date(14)), in: .inbox)).dueAt)
        XCTAssertEqual(try XCTUnwrap(plan(parsed("a", due: date(20, 17)), in: .anytime)).dueAt, date(20, 17))
    }

    func testSomedayListParksAndTagListTags() throws {
        let someday = try XCTUnwrap(plan(parsed("a"), in: .someday))
        XCTAssertEqual(someday.scheduleBucket, .someday)
        XCTAssertNil(someday.dueAt)

        let tagged = try XCTUnwrap(plan(parsed("a", tags: ["x"]), in: .tag("errands")))
        XCTAssertEqual(tagged.tags, ["x", "errands"])
    }

    func testChipsDescribeThePlan() throws {
        let result = try XCTUnwrap(plan(parsed("a", tags: ["home"], priority: .high, project: "Work",
                                               due: date(12, 17), rule: "FREQ=DAILY", bucket: .evening,
                                               minutes: 90), in: .inbox))
        let chips = TaskQuickAddPlanner.chips(for: result, projects: projects, areas: [], calendar: cal, now: now)
        XCTAssertEqual(chips.map(\.kind), [.due, .bucket, .priority, .project, .tag, .duration, .recurrence])
        XCTAssertTrue(chips[0].label.hasPrefix("Tomorrow"))
        XCTAssertEqual(chips[1].label, "This Evening")
        XCTAssertEqual(chips[2].label, "High")
        XCTAssertEqual(chips[3].label, "Work")
        XCTAssertEqual(chips[3].systemImage, "briefcase")
        XCTAssertEqual(chips[4].label, "#home")
        XCTAssertEqual(chips[5].label, "~1h 30m")
        XCTAssertEqual(chips[6].label, "Every day")
    }

    func testUnknownProjectChipWarns() throws {
        let result = try XCTUnwrap(plan(parsed("a", project: "Nope"), in: .anytime))
        let chips = TaskQuickAddPlanner.chips(for: result, projects: projects, areas: [], calendar: cal, now: now)
        XCTAssertEqual(chips.map(\.kind), [.project])
        XCTAssertTrue(chips[0].isWarning)
    }

    func testLabels() {
        XCTAssertEqual(TaskQuickAddPlanner.durationLabel(45), "~45m")
        XCTAssertEqual(TaskQuickAddPlanner.durationLabel(120), "~2h")
        XCTAssertEqual(TaskQuickAddPlanner.dateLabel(date(11), calendar: cal, now: now), "Today")
        XCTAssertEqual(TaskQuickAddPlanner.dateLabel(date(12), calendar: cal, now: now), "Tomorrow")
    }
}
