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

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
            .onAppear(perform: restoreSceneState)
            .onChange(of: navigator.selectedTab) { _, tab in storedTab = tab.rawValue }
            .onChange(of: navigator.visibleNoteId) { _, id in storedNoteId = id ?? "" }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { ScribeiOSBootstrap.sceneDidBecomeActive() }
            }
    }

    private var tabs: some View {
        TabView(selection: $navigator.selectedTab) {
            Tab("Today", systemImage: ScribeMobileTab.today.systemImage, value: ScribeMobileTab.today) {
                TodayScreen()
                    .overlay(alignment: .bottomTrailing) { floatingNewButton }
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

    /// iPhone only: on iPad the sidebar, menu bar and ⌘N / ⌘⇧N cover it.
    @ViewBuilder private var floatingNewButton: some View {
        if horizontalSizeClass == .compact {
            ScribeFloatingNewButton(navigator: navigator)
        }
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
