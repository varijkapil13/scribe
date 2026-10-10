import AppKit
import Combine
import SwiftUI

/// Settings → Reminders. Two-way sync between Scribe tasks and Apple
/// Reminders. Reminders access is requested only when the user turns the sync
/// on here — never at launch.
struct RemindersSettingsPane: View {
    @ObservedObject private var service = RemindersSyncService.shared

    @AppStorage(RemindersSyncSettings.enabledKey) private var enabled: Bool = false
    @AppStorage(RemindersSyncSettings.inboxListKey) private var inboxListId: String = ""
    @AppStorage(RemindersSyncSettings.mapProjectsKey) private var mapProjectsByName: Bool = false
    @AppStorage(RemindersSyncSettings.directionKey) private var direction: RemindersSyncDirection = .twoWay

    @State private var isRequesting = false
    @State private var projects: [Project] = []
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Apple Reminders") {
                Toggle("Sync tasks with Apple Reminders", isOn: Binding(
                    get: { enabled },
                    set: { newValue in setEnabled(newValue) }
                ))
                .disabled(isRequesting)

                HStack {
                    Text("Access")
                    Spacer()
                    if isRequesting {
                        ProgressView().controlSize(.small)
                    }
                    Text(service.access.label)
                        .foregroundStyle(service.access == .granted ? Color.secondary : Color.orange)
                }
                if enabled && service.access != .granted && service.access != .notDetermined {
                    Button("Open Reminders Privacy Settings…") {
                        Permissions.openSystemPreferences(for: "Privacy_Reminders")
                    }
                    Text("Scribe needs full access to Reminders. Turn Scribe on under Privacy & Security → Reminders, then come back here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Tasks and reminders stay in step on this Mac: titles, notes, due dates, priority, completion and simple repeats. The first sync pairs items with the same title and due date, then copies the rest across — it never deletes anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Lists") {
                Picker("Scribe Inbox syncs with", selection: $inboxListId) {
                    Text("Default list").tag("")
                    ForEach(service.lists) { list in
                        Text(list.title).tag(list.id)
                    }
                    if !inboxListId.isEmpty && !service.lists.contains(where: { $0.id == inboxListId }) {
                        Text("Missing list").tag(inboxListId)
                    }
                }
                Toggle("Pair projects with lists of the same name", isOn: $mapProjectsByName)
                if mapProjectsByName {
                    projectPairingSummary
                }
                Text("Only tasks in the Inbox (and in paired projects) are sent to Reminders, and only reminders in those lists come into Scribe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled || service.access != .granted)

            Section("Direction") {
                Picker("Sync direction", selection: $direction) {
                    ForEach(RemindersSyncDirection.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Text(directionCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            Section("Status") {
                HStack {
                    Text(statusText)
                        .foregroundStyle(service.lastError == nil ? Color.secondary : Color.orange)
                    Spacer()
                    if service.isSyncing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Sync Now") {
                        RemindersSyncScheduler.shared.syncNow()
                    }
                    .disabled(!service.isActive || service.isSyncing)
                }
                Button("Forget Pairings…") { confirmReset = true }
                    .disabled(!enabled || service.isSyncing)
                Text("Forgetting pairings never deletes tasks or reminders; the next sync pairs them again by title and due date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
        .confirmationDialog(
            "Forget all task ↔ reminder pairings?",
            isPresented: $confirmReset
        ) {
            Button("Forget Pairings") { service.resetLinks() }
        } message: {
            Text("Nothing is deleted. The next sync re-pairs items that share a title and due date.")
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var projectPairingSummary: some View {
        let mapping = RemindersListMapping.resolve(
            projects: projects,
            lists: service.lists,
            inboxListId: inboxListId.isEmpty ? nil : inboxListId,
            mapProjectsByName: true
        )
        let paired: [String] = projects.filter { mapping.listId(forProjectId: $0.id) != nil }.map(\.name)
        let summary: String = paired.isEmpty
            ? "No project has a list with the same name yet."
            : "Paired: " + paired.joined(separator: ", ")
        Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var directionCaption: String {
        switch direction {
        case .twoWay:
            return "Edits on either side are copied to the other; when both changed, the most recent edit wins."
        case .importOnly:
            return "Reminders are copied into Scribe. Scribe never changes your reminders."
        case .exportOnly:
            return "Scribe tasks are copied into Reminders. Reminders never change your tasks."
        }
    }

    private var statusText: String {
        if let error = service.lastError { return error }
        guard let last = service.lastSyncAt else { return enabled ? "Not synced yet." : "Off." }
        let when = last.formatted(date: .omitted, time: .shortened)
        return "Last synced \(when). \(service.lastSummary ?? "")"
    }

    // MARK: - Actions

    private func reload() {
        service.refreshLists()
        projects = (try? TaskStore.shared.fetchProjects()) ?? []
    }

    private func setEnabled(_ newValue: Bool) {
        guard newValue else {
            service.disable()
            return
        }
        isRequesting = true
        Task {
            let granted = await service.enable()
            isRequesting = false
            if granted { RemindersSyncScheduler.shared.syncNow() }
        }
    }
}
