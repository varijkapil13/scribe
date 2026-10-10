import SwiftUI
import UIKit

/// Settings → Tasks on iPhone / iPad: Apple Reminders two-way sync, calendar
/// events in Today / the planner, reminder notifications + the app badge,
/// and the iCloud task-sync status. Reminders / calendar access is requested
/// only when the matching toggle is turned on here.
struct TasksSettingsScreen: View {
    @ObservedObject private var reminders = RemindersSyncService.shared
    @ObservedObject private var calendarEvents = TasksCalendarEventsModel.shared
    @ObservedObject private var cloud = TasksCloudSyncStatus.shared

    @AppStorage(RemindersSyncSettings.enabledKey) private var remindersEnabled = false
    @AppStorage(RemindersSyncSettings.inboxListKey) private var inboxListId = ""
    @AppStorage(RemindersSyncSettings.mapProjectsKey) private var mapProjectsByName = false
    @AppStorage(RemindersSyncSettings.directionKey) private var direction: RemindersSyncDirection = .twoWay
    @AppStorage(TasksBadgeController.enabledKey) private var badgeEnabled = true

    @State private var isRequestingReminders = false
    @State private var confirmForget = false
    @State private var notificationStatus = ""

    var body: some View {
        Form {
            remindersSection
            if remindersEnabled && reminders.access == .granted {
                remindersOptions
            }
            calendarSection
            notificationsSection
            cloudSection
        }
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
        .onChange(of: badgeEnabled) { TasksBadgeController.shared.refresh() }
        .confirmationDialog("Forget all task ↔ reminder pairings?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Pairings") { reminders.resetLinks() }
        } message: {
            Text("Nothing is deleted. The next sync re-pairs items that share a title and due date.")
        }
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        Section {
            Toggle("Sync with Apple Reminders", isOn: Binding(
                get: { remindersEnabled },
                set: { setRemindersEnabled($0) }
            ))
            .disabled(isRequestingReminders)
            HStack {
                Text("Access")
                Spacer()
                if isRequestingReminders { ProgressView() }
                Text(reminders.access.label)
                    .foregroundStyle(reminders.access == .granted ? Color.secondary : Color.orange)
            }
            if remindersEnabled && reminders.access != .granted && reminders.access != .notDetermined {
                Button("Open Settings to Allow Full Access") { openSystemSettings() }
            }
            if remindersEnabled {
                HStack {
                    Text(remindersStatus)
                        .font(.footnote)
                        .foregroundStyle(reminders.lastError == nil ? Color.secondary : Color.orange)
                    Spacer()
                    if reminders.isSyncing {
                        ProgressView()
                    } else {
                        Button("Sync Now") { RemindersSyncScheduler.shared.syncNow() }
                            .disabled(!reminders.isActive)
                    }
                }
            }
        } header: {
            Text("Apple Reminders")
        } footer: {
            Text("Titles, notes, due dates, priority, completion and simple repeats stay in step. The first sync pairs items with the same title and due date, then copies the rest — it never deletes anything.")
        }
    }

    private var remindersOptions: some View {
        Section {
            Picker("Inbox syncs with", selection: $inboxListId) {
                Text("Default list").tag("")
                ForEach(reminders.lists) { list in
                    Text(list.title).tag(list.id)
                }
                if !inboxListId.isEmpty && !reminders.lists.contains(where: { $0.id == inboxListId }) {
                    Text("Missing list").tag(inboxListId)
                }
            }
            Toggle("Pair projects with same-named lists", isOn: $mapProjectsByName)
            Picker("Direction", selection: $direction) {
                ForEach(RemindersSyncDirection.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Button("Forget Pairings…") { confirmForget = true }
                .disabled(reminders.isSyncing)
        } footer: {
            Text("Only Inbox tasks (and tasks in paired projects) go to Reminders, and only reminders in those lists come into Scribe.")
        }
    }

    private var remindersStatus: String {
        if let error = reminders.lastError { return error }
        guard let last = reminders.lastSyncAt else { return "Not synced yet." }
        return "Last synced \(last.formatted(date: .omitted, time: .shortened)). \(reminders.lastSummary ?? "")"
    }

    // MARK: - Calendar

    private var calendarSection: some View {
        Section {
            Toggle("Show calendar events", isOn: Binding(
                get: { calendarEvents.isEnabled },
                set: { on in
                    if on { Task { await calendarEvents.enable() } } else { calendarEvents.disable() }
                }
            ))
            if calendarEvents.isEnabled && !calendarEvents.isGranted {
                Button("Open Settings to Allow Calendar Access") { openSystemSettings() }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Today lists the day’s events and meetings (with join links), and the planner lays tasks out next to them.")
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            HStack {
                Text("Notifications")
                Spacer()
                Text(notificationStatus).foregroundStyle(.secondary)
            }
            Toggle("Badge app icon with Today count", isOn: $badgeEnabled)
            Button("Notification Settings…") { openSystemSettings() }
        } header: {
            Text("Reminders & Badge")
        } footer: {
            Text("Task reminders alert you at the set time, with Mark Done and Snooze 15 min actions. The badge counts overdue and Today tasks.")
        }
    }

    // MARK: - iCloud

    private var cloudSection: some View {
        Section {
            HStack {
                Label(cloud.statusText, systemImage: cloud.symbol)
                    .foregroundStyle(cloud.lastError == nil ? Color.primary : Color.orange)
                Spacer()
                if cloud.isSyncing { ProgressView() }
            }
            if cloud.isEnabled {
                Button("Sync Tasks Now") { Task { await cloud.syncNow() } }
                    .disabled(cloud.isSyncing)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Turn iCloud task sync on or off in Settings → iCloud. Dates, start dates, Today / Evening / Someday plans, durations and repeats sync across your devices.")
        }
    }

    // MARK: - Actions

    private func reload() {
        reminders.refreshLists()
        calendarEvents.refreshAccess()
        cloud.refresh()
        Task { notificationStatus = await TasksNotificationBridge.authorizationSummary() }
    }

    private func setRemindersEnabled(_ on: Bool) {
        guard on else {
            reminders.disable()
            return
        }
        isRequestingReminders = true
        Task {
            let granted = await reminders.enable()
            isRequestingReminders = false
            if granted { RemindersSyncScheduler.shared.syncNow() }
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
