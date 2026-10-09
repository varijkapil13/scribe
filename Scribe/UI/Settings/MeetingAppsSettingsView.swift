import SwiftUI

/// Extra rows for the "Meeting detection" section of General settings: the
/// camera signal toggle and a "Manage apps…" button that opens
/// ``MeetingAppsSettingsView`` as a sheet.
struct MeetingDetectionExtraSettings: View {
    let detectionEnabled: Bool

    @AppStorage(MeetingSignals.useCameraKey) private var useCamera: Bool = true
    @State private var showingApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Toggle("Treat camera + microphone as a video call", isOn: $useCamera)
            Text("When a camera is on, a browser or any other app using the microphone counts as a meeting, and Scribe reacts sooner. Scribe only checks whether a camera is running; it never opens it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!detectionEnabled)

        HStack {
            Text("Meeting apps")
            Spacer()
            Button("Manage Apps…") { showingApps = true }
        }
        .disabled(!detectionEnabled)
        .sheet(isPresented: $showingApps) {
            MeetingAppsSettingsView()
        }
    }
}

/// Backing store for ``MeetingAppsSettingsView``: the user's per-app rules
/// and the non-catalog apps seen using the mic, read from and written straight
/// back to `UserDefaults` (which `MeetingDetector` re-reads every poll).
@MainActor
final class MeetingAppsSettingsModel: ObservableObject {

    struct OtherApp: Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    @Published private(set) var rules: MeetingAppRules
    @Published private(set) var otherApps: [OtherApp] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rules = MeetingAppRules.load(from: defaults)
        reloadOtherApps()
    }

    func reloadOtherApps() {
        otherApps = Self.otherApps(seen: MeetingAppHistory.load(from: defaults), rules: rules)
    }

    /// Seen apps plus any opted-in app no longer in the seen list (so an
    /// opt-in can always be undone), sorted by name.
    nonisolated static func otherApps(seen: [String: String], rules: MeetingAppRules) -> [OtherApp] {
        var all = seen
        for id in rules.alwaysCounted where all[id] == nil { all[id] = id }
        return all
            .map { OtherApp(bundleID: $0.key, name: $0.value) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order == .orderedSame ? lhs.bundleID < rhs.bundleID : order == .orderedAscending
            }
    }

    func isEnabled(_ entry: MeetingAppCatalog.Entry) -> Bool {
        !entry.bundleIDs.contains { rules.isDisabled($0) }
    }

    func setEnabled(_ entry: MeetingAppCatalog.Entry, _ enabled: Bool) {
        rules.setCatalogApp(entry.bundleIDs, enabled: enabled)
        rules.save(to: defaults)
    }

    func isCounted(_ app: OtherApp, includeOtherApps: Bool) -> Bool {
        rules.countsOtherApp(app.bundleID, includeOtherApps: includeOtherApps)
    }

    func setCounted(_ app: OtherApp, _ counted: Bool, includeOtherApps: Bool) {
        rules.setOtherApp(app.bundleID, counted: counted, includeOtherApps: includeOtherApps)
        rules.save(to: defaults)
    }

    /// Removes an app from the seen list and drops any rule about it.
    func forget(_ app: OtherApp) {
        rules.alwaysCounted.remove(app.bundleID)
        rules.disabled.remove(app.bundleID)
        rules.save(to: defaults)
        MeetingAppHistory.forget(app.bundleID, in: defaults)
        reloadOtherApps()
    }
}

/// Per-app allow/deny list for meeting detection: every catalog app with an
/// on/off switch, plus any other app Scribe has seen using the microphone
/// with an "always count" switch.
struct MeetingAppsSettingsView: View {
    @StateObject private var model = MeetingAppsSettingsModel()
    @AppStorage(MeetingDetector.includeBrowsersKey) private var includeBrowsers: Bool = true
    @AppStorage(MeetingDetector.includeOtherAppsKey) private var includeOtherApps: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(MeetingAppCatalog.entries(kind: .conferencing)) { entry in
                        Toggle(entry.name, isOn: binding(for: entry))
                    }
                } header: {
                    Text("Call apps")
                } footer: {
                    Text("Turn an app off if you use it for things other than meetings.")
                }

                Section {
                    ForEach(MeetingAppCatalog.entries(kind: .browser)) { entry in
                        Toggle(entry.name, isOn: binding(for: entry))
                            .disabled(!includeBrowsers)
                    }
                } header: {
                    Text("Web browsers")
                } footer: {
                    if !includeBrowsers {
                        Text("Browser calls are turned off in Meeting detection settings. A browser still counts while your camera is on, unless you switch it off here.")
                    }
                }

                Section {
                    if model.otherApps.isEmpty {
                        Text("Apps that use your microphone appear here, so you can choose to treat them as meetings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.otherApps) { app in
                            Toggle(isOn: binding(for: app)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.bundleID)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu {
                                Button("Forget This App") { model.forget(app) }
                            }
                        }
                    }
                } header: {
                    Text("Other apps seen using the microphone")
                } footer: {
                    Text(includeOtherApps
                         ? "\"Include any other app\" is on, so these count unless switched off."
                         : "Switch an app on to always count it as a meeting.")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DesignTokens.Spacing.md)
        }
        .frame(width: 480, height: 540)
        .onAppear { model.reloadOtherApps() }
    }

    private func binding(for entry: MeetingAppCatalog.Entry) -> Binding<Bool> {
        Binding(
            get: { model.isEnabled(entry) },
            set: { model.setEnabled(entry, $0) }
        )
    }

    private func binding(for app: MeetingAppsSettingsModel.OtherApp) -> Binding<Bool> {
        Binding(
            get: { model.isCounted(app, includeOtherApps: includeOtherApps) },
            set: { model.setCounted(app, $0, includeOtherApps: includeOtherApps) }
        )
    }
}
