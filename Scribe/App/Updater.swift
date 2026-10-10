import Combine
import Foundation
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

/// Whether in-app updates can run in this copy of Scribe, and if not, why.
enum ScribeUpdaterAvailability: Equatable, Sendable {
    /// Sparkle is running.
    case available
    /// This build has no update feed / EdDSA public key (dev builds, forks),
    /// or Sparkle isn't linked. The updater is simply not started.
    case notConfigured
    /// Installed by a Homebrew cask that doesn't let the app update itself.
    case managedByHomebrew
    /// UI tests / screenshot fixtures never touch the network.
    case disabledForTesting

    /// Pure resolution of the launch inputs (pinned by tests).
    ///
    /// `publicKey` is Info.plist `SUPublicEDKey`, which the build fills from
    /// `$(SPARKLE_PUBLIC_ED_KEY)`; an empty or unexpanded value means the build
    /// was not configured for updates, and starting Sparkle would only show
    /// its "updater failed to start" alert.
    nonisolated static func resolve(
        isTesting: Bool,
        sparkleLinked: Bool,
        feedURL: String?,
        publicKey: String?,
        homebrew: ScribeHomebrewUpdatePolicy
    ) -> ScribeUpdaterAvailability {
        if isTesting { return .disabledForTesting }
        if homebrew == .managedByHomebrew { return .managedByHomebrew }
        guard sparkleLinked else { return .notConfigured }
        guard isUsableSetting(feedURL), let feedURL, feedURL.hasPrefix("https://") else { return .notConfigured }
        guard isUsableSetting(publicKey) else { return .notConfigured }
        return .available
    }

    /// Non-empty and not an unexpanded `$(BUILD_SETTING)` reference.
    nonisolated static func isUsableSetting(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("$(")
    }

    /// One-line explanation for Settings › About › Updates.
    var explanation: String {
        switch self {
        case .available:
            return "Scribe checks GitHub Releases for signed updates. Only the update feed is fetched; nothing about you or your notes is sent."
        case .notConfigured:
            return "This build isn't set up for automatic updates. Download new versions from GitHub Releases."
        case .managedByHomebrew:
            return "Updates are managed by Homebrew. Run `brew upgrade --cask scribe` to update."
        case .disabledForTesting:
            return "Updates are disabled while testing."
        }
    }
}

/// Owns Sparkle's `SPUStandardUpdaterController` and mirrors the settings the
/// UI shows. All Sparkle API use is in this file, behind `canImport(Sparkle)`,
/// so the SwiftPM test build compiles whether or not the package links.
@MainActor
final class ScribeUpdater: ObservableObject {

    static let shared = ScribeUpdater()

    @Published private(set) var availability: ScribeUpdaterAvailability = .notConfigured
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false

    private var started = false
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif

    private init() {}

    nonisolated static var isSparkleLinked: Bool {
        #if canImport(Sparkle)
        return true
        #else
        return false
        #endif
    }

    /// Called once at launch (AppDelegate). Resolves availability and, when
    /// everything is configured, starts Sparkle's scheduled checks.
    func start() {
        guard !started else { return }
        started = true

        let info = Bundle.main.infoDictionary ?? [:]
        let isTesting = AppLaunchEnvironment.isUITesting || AppLaunchEnvironment.usesUITestFixtures
        let homebrew: ScribeHomebrewUpdatePolicy = isTesting ? .notHomebrew : ScribeHomebrewInstallDetector.detect()
        availability = ScribeUpdaterAvailability.resolve(
            isTesting: isTesting,
            sparkleLinked: Self.isSparkleLinked,
            feedURL: info["SUFeedURL"] as? String,
            publicKey: info["SUPublicEDKey"] as? String,
            homebrew: homebrew
        )
        guard availability == .available else {
            Log.app.info("Updater not started: \(String(describing: self.availability), privacy: .public)")
            return
        }
        startSparkle()
    }

    // MARK: - Actions

    func checkForUpdates() {
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        #if canImport(Sparkle)
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        refreshSettings()
        #endif
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        #if canImport(Sparkle)
        guard let updater = controller?.updater else { return }
        updater.automaticallyDownloadsUpdates = enabled
        refreshSettings()
        #endif
    }

    // MARK: - Sparkle

    /// The only place that creates Sparkle objects. If a Sparkle API change
    /// breaks the build, this is the function to fix.
    private func startSparkle() {
        #if canImport(Sparkle)
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        observeCanCheckForUpdates(controller.updater)
        refreshSettings()
        #endif
    }

    #if canImport(Sparkle)
    /// Mirrors `SPUUpdater.canCheckForUpdates` (KVO, changed by Sparkle on the
    /// main thread) into `@Published`, as in Sparkle's SwiftUI guide.
    private func observeCanCheckForUpdates(_ updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
    #endif

    private func refreshSettings() {
        #if canImport(Sparkle)
        guard let updater = controller?.updater else { return }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        #endif
    }
}

// MARK: - Menu

/// Scribe › Check for Updates… (after About Scribe).
struct ScribeUpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesMenuItem()
        }
    }
}

private struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var updater: ScribeUpdater = .shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(updater.availability != .available || !updater.canCheckForUpdates)
    }
}

// MARK: - Settings

/// Settings › About › Updates.
struct UpdatesSettingsSection: View {
    @ObservedObject private var updater: ScribeUpdater = .shared

    var body: some View {
        Section("Updates") {
            if updater.availability == .available {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.setAutomaticallyDownloadsUpdates($0) }
                ))
                .disabled(!updater.automaticallyChecksForUpdates)
                HStack {
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            Text(LocalizedStringKey(updater.availability.explanation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
