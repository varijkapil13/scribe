// Scribe/ExtensionBridge/ScribeExtensionsBridge.swift
//
// The app's single hook-up point for its extensions (Extensions/ in the
// repo): the widget snapshot publisher, the widget task-request applier and
// the Share-extension inbox importer. AppDelegate calls `start()` at launch
// and `appDidBecomeActive()`; the `scribe://import-share` link lands in
// `handleImportShareLink()` via ScribeEntryRouter.

import Foundation

@MainActor
final class ScribeExtensionsBridge {

    static let shared = ScribeExtensionsBridge()

    private var started = false
    private var publisher: WidgetSnapshotPublisher?
    private var applier: WidgetTaskRequestApplier?

    private init() {}

    // MARK: - Lifecycle

    /// Called once from `applicationDidFinishLaunching`. No-op under UI
    /// testing / fixture runs (they must never touch the real App Group) and
    /// when the App Group container is unavailable (unsigned builds).
    func start() {
        guard !started else { return }
        started = true
        guard !AppLaunchEnvironment.isUITesting, !AppLaunchEnvironment.usesUITestFixtures else { return }
        guard let container = ScribeAppGroup.containerURL() else {
            Log.app.info("App Group container unavailable; widgets and Share extension hand-off are off.")
            return
        }

        let applier = WidgetTaskRequestApplier(
            queue: ScribeWidgetRequestQueue(container: container),
            taskStore: TaskStore.shared,
            onTaskChanged: { task in WidgetTaskRequestApplier.rescheduleReminder(for: task) }
        )
        self.applier = applier
        applier.drain()
        applier.startObserving()

        let publisher = WidgetSnapshotPublisher(
            store: ScribeSharedSnapshotStore(directory: container),
            taskStore: TaskStore.shared,
            debounce: .seconds(1)
        )
        self.publisher = publisher
        publisher.start(database: DatabaseManager.shared.database)

        // Shares made while Scribe wasn't running (or whose link was lost).
        importSharedItems(navigate: false)
    }

    func appDidBecomeActive() {
        applier?.drain()
        publisher?.setNeedsPublish(force: true)
    }

    /// Darwin notification from a widget toggle.
    func widgetRequestsArrived() {
        applier?.drain()
        publisher?.setNeedsPublish(force: true)
    }

    // MARK: - Share inbox

    /// `scribe://import-share`: import everything pending and open the last
    /// imported item.
    func handleImportShareLink() {
        importSharedItems(navigate: true)
    }

    private func importSharedItems(navigate: Bool) {
        // Not gated on `started`: on a cold launch from the Share extension
        // the queued link is routed before `start()` runs.
        guard !AppLaunchEnvironment.isUITesting, !AppLaunchEnvironment.usesUITestFixtures,
              let inbox = ScribeShareInbox.appGroup() else { return }
        let noteStore = NoteStore.shared
        let importer = ScribeShareInboxImporter(
            noteStore: noteStore,
            taskStore: TaskStore.shared,
            inbox: inbox,
            attachmentsRoot: noteStore.fileStore?.directory.root ?? AttachmentsDirectory.defaultRoot()
        )
        let result = importer.importPending(timeZone: .current)
        for failure in result.failures {
            AppState.shared.report(failure)
        }
        guard let last = result.outcomes.last else { return }
        let message = result.outcomes.count == 1
            ? last.message
            : "Imported \(result.outcomes.count) shared items"
        AppState.shared.notify(message)
        if navigate {
            ScribeEntryRouter.shared.show(last.selection)
        }
    }
}
