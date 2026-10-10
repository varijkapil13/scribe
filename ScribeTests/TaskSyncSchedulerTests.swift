import XCTest
@testable import Scribe

/// Pure trigger rules for automatic task sync on the Mac.
final class TaskSyncTriggerPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testLaunchAndEnableAlwaysStartWhenIdle() {
        let policy = TaskSyncTriggerPolicy()
        XCTAssertTrue(policy.shouldStart(.launch, now: t0))
        XCTAssertTrue(policy.shouldStart(.enabled, now: t0))
    }

    func testNothingStartsWhileARoundIsRunning() {
        var policy = TaskSyncTriggerPolicy()
        policy.didStart(at: t0)
        for trigger: TaskSyncTriggerPolicy.Trigger in [.launch, .enabled, .activation, .localChange] {
            XCTAssertFalse(policy.shouldStart(trigger, now: t0.addingTimeInterval(3_600)), "\(trigger)")
        }
        XCTAssertFalse(policy.acceptsLocalChange(now: t0.addingTimeInterval(1)))
    }

    func testActivationIsThrottled() {
        var policy = TaskSyncTriggerPolicy(activationInterval: 300, postSyncQuietPeriod: 3)
        XCTAssertTrue(policy.shouldStart(.activation, now: t0))
        policy.didStart(at: t0)
        policy.didFinish(at: t0.addingTimeInterval(2))
        XCTAssertFalse(policy.shouldStart(.activation, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(policy.shouldStart(.activation, now: t0.addingTimeInterval(300)))
    }

    func testLocalChangesRightAfterARoundAreTreatedAsEchoes() {
        var policy = TaskSyncTriggerPolicy(activationInterval: 300, postSyncQuietPeriod: 3)
        policy.didStart(at: t0)
        policy.didFinish(at: t0.addingTimeInterval(1))
        XCTAssertFalse(policy.acceptsLocalChange(now: t0.addingTimeInterval(2)))
        XCTAssertFalse(policy.shouldStart(.localChange, now: t0.addingTimeInterval(2)))
        XCTAssertTrue(policy.acceptsLocalChange(now: t0.addingTimeInterval(5)))
        XCTAssertTrue(policy.shouldStart(.localChange, now: t0.addingTimeInterval(5)))
    }
}

/// CloudKit entitlement parsing (the gate that keeps an un-entitled Mac build
/// from constructing a CKContainer, which would crash).
final class CloudKitAvailabilityTests: XCTestCase {

    func testEntitlementValueParsing() {
        XCTAssertTrue(CloudKitAvailability.entitlementValueIncludesCloudKit(["CloudKit", "CloudDocuments"]))
        XCTAssertTrue(CloudKitAvailability.entitlementValueIncludesCloudKit(["*"]))
        XCTAssertTrue(CloudKitAvailability.entitlementValueIncludesCloudKit("CloudKit"))
        XCTAssertFalse(CloudKitAvailability.entitlementValueIncludesCloudKit(["CloudDocuments"]))
        XCTAssertFalse(CloudKitAvailability.entitlementValueIncludesCloudKit(nil))
        XCTAssertFalse(CloudKitAvailability.entitlementValueIncludesCloudKit(42))
    }
}

@MainActor
final class TaskSyncSchedulerTests: XCTestCase {

    /// Main-actor box (Sendable via isolation) so the @MainActor closures
    /// below capture no mutable locals or non-Sendable state.
    @MainActor
    private final class Counter {
        var runs = 0
        var toggle = true
    }

    private func makeScheduler(
        allowed: Bool = true,
        counter: Counter,
        debounce: Duration = .milliseconds(50),
        syncDuration: Duration? = nil
    ) -> TaskSyncScheduler {
        TaskSyncScheduler(
            policy: TaskSyncTriggerPolicy(activationInterval: 300, postSyncQuietPeriod: 0),
            localChangeDebounce: debounce,
            isSyncAllowed: { allowed },
            isToggleOn: { counter.toggle },
            runSync: {
                counter.runs += 1
                if let syncDuration { try await Task.sleep(for: syncDuration) }
            }
        )
    }

    func testRequestRunsOneRoundWhenAllowed() async {
        let counter = Counter()
        let scheduler = makeScheduler(counter: counter)
        scheduler.request(.launch)
        await scheduler.inFlight?.value
        XCTAssertEqual(counter.runs, 1)
        XCTAssertFalse(scheduler.isSyncing)
    }

    func testNothingRunsWhenSyncIsNotAllowed() async {
        let counter = Counter()
        let scheduler = makeScheduler(allowed: false, counter: counter)
        scheduler.request(.launch)
        scheduler.request(.enabled)
        scheduler.appDidBecomeActive()
        XCTAssertNil(scheduler.inFlight)
        XCTAssertEqual(counter.runs, 0)
    }

    func testActivationRightAfterLaunchIsThrottled() async {
        let counter = Counter()
        let scheduler = makeScheduler(counter: counter)
        scheduler.request(.launch)
        await scheduler.inFlight?.value
        scheduler.appDidBecomeActive()
        await scheduler.inFlight?.value
        XCTAssertEqual(counter.runs, 1)
    }

    func testTurningTheToggleOnTriggersARound() async {
        let counter = Counter()
        counter.toggle = false
        let scheduler = makeScheduler(counter: counter)
        scheduler.defaultsDidChange()   // records "off"
        XCTAssertNil(scheduler.inFlight)
        counter.toggle = true
        scheduler.defaultsDidChange()   // off -> on
        await scheduler.inFlight?.value
        XCTAssertEqual(counter.runs, 1)
        scheduler.defaultsDidChange()   // still on: no new round
        XCTAssertNil(scheduler.inFlight)
        XCTAssertEqual(counter.runs, 1)
    }

    func testLocalTaskEditsAreDebouncedIntoOneRound() async throws {
        let counter = Counter()
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        counter.toggle = false
        let scheduler = makeScheduler(counter: counter)
        scheduler.start(database: manager.database)
        // start() requests a launch round; let it finish.
        await scheduler.inFlight?.value
        let baseline = counter.runs

        _ = try store.createTask(title: "One")
        _ = try store.createTask(title: "Two")
        _ = try store.createTask(title: "Three")

        let deadline = Date().addingTimeInterval(3)
        while counter.runs == baseline, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await scheduler.inFlight?.value
        XCTAssertEqual(counter.runs, baseline + 1, "Three quick edits should coalesce into one round")
    }

    func testLocalEditDuringARoundTriggersAFollowUpRound() async throws {
        let counter = Counter()
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let scheduler = makeScheduler(counter: counter, syncDuration: .milliseconds(200))
        scheduler.start(database: manager.database)   // launch round, still running
        XCTAssertTrue(scheduler.isSyncing)

        // Edit while the launch round is in flight: it must not be dropped.
        _ = try store.createTask(title: "Edited mid-sync")
        await scheduler.inFlight?.value
        XCTAssertEqual(counter.runs, 1)

        let deadline = Date().addingTimeInterval(3)
        while counter.runs == 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await scheduler.inFlight?.value
        XCTAssertEqual(counter.runs, 2, "An edit made during a round should get one follow-up round")
    }
}
