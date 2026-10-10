import CoreSpotlight
import SwiftUI

/// Top-level iPhone/iPad navigation, built on the iOS 18+ `Tab` API with
/// `.sidebarAdaptable`: a (Liquid Glass) tab bar on iPhone, a sidebar on iPad
/// that the user can collapse back to a tab bar. The user's tab arrangement
/// is persisted (`TabViewCustomization` in `@AppStorage`), the selected tab
/// and open note per window (`@SceneStorage`).
///
/// Each area root owns its own `NavigationStack`; entry points reach them
/// through the scene's `ScribeiOSNavigator` (see ScribeiOSNavigator.swift).
struct RootTabView: View {
    @State private var navigator = ScribeiOSNavigator(
        selectedTab: .today,
        noteStore: NoteStore.shared,
        taskStore: TaskStore.shared
    )

    // CI-COMPILE NOTE: `AppStorage` has a dedicated initializer for
    // `TabViewCustomization` (no default value). If it ever fails to
    // resolve, persist the customization as JSON Data instead.
    @AppStorage("ios.tabViewCustomization") private var customization: TabViewCustomization

    @SceneStorage("scribe.selectedTab") private var storedTab: String = ScribeMobileTab.today.rawValue
    @SceneStorage("scribe.visibleNoteId") private var storedNoteId: String = ""
    @State private var didRestore = false

    @AppStorage(ScribeMobileAppearance.storageKey) private var appearanceRaw: String = ScribeMobileAppearance.system.rawValue

    /// Tapped task reminders (and the iPhone planner) post here; this scene
    /// routes them through its navigator (see `consumeTaskOpenRequest`).
    @ObservedObject private var taskOpenRequest = TasksOpenRequest.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        tabs
            .environment(navigator)
            .focusedSceneValue(\.scribeiOSNavigator, navigator)
            .preferredColorScheme(colorScheme)
            .sheet(isPresented: $navigator.isNewTaskSheetPresented) {
                ScribeQuickTaskSheet { task in navigator.openTask(task.id) }
            }
            .alert(navigator.alertMessage ?? "", isPresented: alertPresented) {
                Button("OK", role: .cancel) {}
            }
            // Entry points: scribe:// links, Handoff from the Mac (or another
            // iPad/iPhone), and Spotlight results.
            .onOpenURL { url in _ = navigator.handle(url: url) }
            .onContinueUserActivity(ScribeUserActivity.viewNote) { activity in _ = navigator.handle(activity: activity) }
            .onContinueUserActivity(ScribeUserActivity.viewTask) { activity in _ = navigator.handle(activity: activity) }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in _ = navigator.handle(activity: activity) }
            // A note-row drag normally spawns a note window (that scene
            // matches the drag's target content identifier); if iPadOS hands
            // it to a main window instead, open the note here rather than
            // dropping it.
            .onContinueUserActivity(ScribeMobileWindows.openNoteWindowActivityType) { activity in _ = navigator.handle(activity: activity) }
            .onAppear {
                restoreSceneState()
                consumeTaskOpenRequest()
            }
            .onChange(of: navigator.selectedTab) { _, tab in storedTab = tab.rawValue }
            .onChange(of: navigator.visibleNoteId) { _, id in storedNoteId = id ?? "" }
            .onChange(of: taskOpenRequest.taskId) { _, _ in consumeTaskOpenRequest() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    ScribeiOSBootstrap.sceneDidBecomeActive()
                    consumeTaskOpenRequest()
                }
            }
    }

    private var tabs: some View {
        TabView(selection: $navigator.selectedTab) {
            // Today carries its own floating + (quick add filed into Today);
            // New Note / New Task are also ⌘N / ⌘⇧N and the Notes / Tasks tabs.
            Tab("Today", systemImage: ScribeMobileTab.today.systemImage, value: ScribeMobileTab.today) {
                TodayScreen()
            }
            .customizationID(ScribeMobileTab.today.customizationID)

            Tab("Notes", systemImage: ScribeMobileTab.notes.systemImage, value: ScribeMobileTab.notes) {
                NotesRootView()
            }
            .customizationID(ScribeMobileTab.notes.customizationID)

            Tab("Tasks", systemImage: ScribeMobileTab.tasks.systemImage, value: ScribeMobileTab.tasks) {
                TasksRootView()
            }
            .customizationID(ScribeMobileTab.tasks.customizationID)

            Tab("Record", systemImage: ScribeMobileTab.record.systemImage, value: ScribeMobileTab.record) {
                RecordingsRootView()
            }
            .customizationID(ScribeMobileTab.record.customizationID)

            Tab("Settings", systemImage: ScribeMobileTab.settings.systemImage, value: ScribeMobileTab.settings) {
                SettingsScreen()
            }
            .customizationID(ScribeMobileTab.settings.customizationID)

            // The system places the search tab apart (trailing on the iPhone
            // tab bar, top of the iPad sidebar) and supplies its label.
            // CI-COMPILE NOTE: if `Tab(value:role:content:)` doesn't resolve,
            // use `Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search)`.
            Tab(value: ScribeMobileTab.search, role: .search) {
                UniversalSearchScreen()
            }
            .customizationID(ScribeMobileTab.search.customizationID)
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewCustomization($customization)
    }

    private var colorScheme: ColorScheme? {
        switch ScribeMobileAppearance.resolved(from: appearanceRaw) {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { navigator.alertMessage != nil },
            set: { if !$0 { navigator.alertMessage = nil } }
        )
    }

    /// A task reminder was tapped (or the iPhone planner opened a task):
    /// open it in this window unless the window is in the background (with
    /// several iPad windows the first foreground one takes it).
    private func consumeTaskOpenRequest() {
        guard scenePhase != .background, let taskId = taskOpenRequest.taskId else { return }
        taskOpenRequest.taskId = nil
        navigator.openTask(taskId)
    }

    /// Restores this window's tab (and open note) once, unless an entry
    /// point (a cold-launch deep link, Handoff) already routed it.
    private func restoreSceneState() {
        guard !didRestore else { return }
        didRestore = true
        guard !navigator.hasRouted else { return }
        let tab = ScribeMobileTab.restored(from: storedTab)
        navigator.selectedTab = tab
        let noteId = storedNoteId
        if tab == .notes, !noteId.isEmpty, (try? NoteStore.shared.fetchNote(id: noteId)) != nil {
            navigator.openNote(noteId)
        }
    }
}
