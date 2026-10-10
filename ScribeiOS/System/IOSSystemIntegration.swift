// ScribeiOS/System/IOSSystemIntegration.swift
//
// The iOS app's hook-up point for system integration (the iOS counterpart of
// the Mac's ScribeExtensionsBridge + the Spotlight start in
// ScribeIntentsBridge.didFinishLaunching):
//
//   • Spotlight indexing of notes and tasks (SpotlightIndexer, portable);
//   • the widget snapshot in the App Group + timeline reloads
//     (IOSWidgetSnapshotPublisher);
//   • task completions queued by the interactive widgets
//     (WidgetTaskRequestApplier, portable);
//   • items saved by the Share extension (ScribeShareInboxImporter, portable).
//
// Driven by `.scribeSystemIntegration()` (ScribeSystemIntegrationModifier) on
// each scene's root: `start()` once, then scene activation / backgrounding.
// Everything degrades to a no-op when the App Group container is missing
// (unsigned builds, CI).

import Foundation
import Observation
import UIKit

/// A short message shown over the app (e.g. after importing a share).
struct IOSSystemBanner: Equatable, Identifiable {
    let id: UUID
    let message: String
    /// Opened by the banner's "Show" button.
    let link: URL?
    let isError: Bool

    init(message: String, link: URL?, isError: Bool = false) {
        self.id = UUID()
        self.message = message
        self.link = link
        self.isError = isError
    }
}

@MainActor
@Observable
final class IOSSystemIntegration {

    static let shared = IOSSystemIntegration()

    /// The banner currently shown (cleared after a few seconds).
    private(set) var banner: IOSSystemBanner?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var publisher: IOSWidgetSnapshotPublisher?
    @ObservationIgnored private var applier: WidgetTaskRequestApplier?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    /// Optional direct router for scribe:// links (the shell may install
    /// one); without it links go through `UIApplication.open`, which
    /// delivers them back to this app's `onOpenURL`.
    static var linkRouter: (@MainActor (URL) -> Bool)?

    private init() {}

    private var isEnabledForThisLaunch: Bool {
        !AppLaunchEnvironment.isUITesting && !AppLaunchEnvironment.usesUITestFixtures
    }

    // MARK: - Lifecycle

    /// Once per launch (idempotent; every scene calls it).
    func start() {
        guard !started else { return }
        started = true
        guard isEnabledForThisLaunch else { return }

        SpotlightIndexer.shared.start()

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
        WidgetTaskRequestApplier.darwinRequestHandler = {
            IOSSystemIntegration.shared.widgetRequestsArrived()
        }
        applier.drain()
        applier.startObserving()

        let publisher = IOSWidgetSnapshotPublisher(
            store: ScribeSharedSnapshotStore(directory: container),
            taskStore: TaskStore.shared,
            debounce: .seconds(1)
        )
        self.publisher = publisher
        publisher.start(database: DatabaseManager.shared.database)

        importSharedItems()
    }

    /// A scene became active: apply widget taps, import shares, refresh the
    /// snapshot (a widget may have written an optimistic one).
    func sceneDidBecomeActive() {
        guard started, isEnabledForThisLaunch else { return }
        applier?.drain()
        importSharedItems()
        publisher?.setNeedsPublish(force: true)
    }

    /// A scene went to the background: write the snapshot now, while the app
    /// still runs, so the Home Screen shows current tasks.
    func sceneDidEnterBackground() {
        guard started, isEnabledForThisLaunch else { return }
        publisher?.publishNow(force: true)
    }

    /// Darwin notification from a widget toggle (the app is running, e.g.
    /// recording in the background).
    func widgetRequestsArrived() {
        applier?.drain()
        publisher?.setNeedsPublish(force: true)
    }

    func recordingStateDidChange() {
        publisher?.setNeedsPublish(force: false)
    }

    // MARK: - Share inbox

    /// Imports everything the Share extension queued. iOS doesn't let a
    /// Share extension open its app, so this runs whenever Scribe becomes
    /// active; a banner offers to open what was imported.
    func importSharedItems() {
        guard isEnabledForThisLaunch, let inbox = ScribeShareInbox.appGroup() else { return }
        let noteStore = NoteStore.shared
        let importer = ScribeShareInboxImporter(
            noteStore: noteStore,
            taskStore: TaskStore.shared,
            inbox: inbox,
            attachmentsRoot: noteStore.fileStore?.directory.root ?? AttachmentsDirectory.defaultRoot()
        )
        let result = importer.importPending(timeZone: .current)
        for failure in result.failures {
            Log.app.error("Share import: \(failure, privacy: .public)")
        }
        if let last = result.outcomes.last {
            let message = result.outcomes.count == 1
                ? last.message
                : "Imported \(result.outcomes.count) shared items"
            show(IOSSystemBanner(message: message, link: last.deepLinkURL))
        } else if let failure = result.failures.last {
            show(IOSSystemBanner(message: failure, link: nil, isError: true))
        }
    }

    // MARK: - Banner

    func show(_ banner: IOSSystemBanner) {
        self.banner = banner
        bannerTask?.cancel()
        let id = banner.id
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.banner?.id == id else { return }
            self.banner = nil
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    // MARK: - Links

    /// Opens a scribe:// link inside the app (the shell routes it).
    static func openInApp(_ url: URL) {
        if let router = linkRouter, router(url) { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
