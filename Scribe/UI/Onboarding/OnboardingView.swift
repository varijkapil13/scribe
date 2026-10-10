import AppKit
import SwiftUI

/// First-run onboarding sheet: a short paged flow (see `OnboardingStep`).
///
/// 1. Welcome — the three surfaces and the on-device promise.
/// 2. Permissions — microphone, system audio, speech and notifications with
///    live status (refreshed when Scribe becomes active again, so a grant
///    made in System Settings shows up immediately).
/// 3. Meetings — the auto-detection mode and system-audio capture.
/// 4. Vault — where notes are stored, with a folder picker.
/// 5. Done — the shortcuts worth knowing.
///
/// Shown once per `OnboardingGate.currentVersion`; Skip, Escape and Get
/// Started all mark it completed. Steps crossfade under Reduce Motion.
struct OnboardingView: View {

    /// Bound to the presenting sheet so Skip / Done / Escape can dismiss it.
    @Binding var isPresented: Bool

    /// Drives the mic preview meter on the permissions step.
    @ObservedObject var audioManager: AudioSessionManager

    @AppStorage("captureSystemAudio") private var captureSystemAudio: Bool = true
    @AppStorage(MeetingDetectionMode.defaultsKey) private var meetingDetectionMode: MeetingDetectionMode = MeetingDetectionMode.defaultValue
    @ObservedObject private var vault: VaultCoordinator = .shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scribeAccent) private var accent

    @State private var step: OnboardingStep = .welcome
    @State private var permissions: [PrivacyPermissionKind: PrivacyPermissionState] = [:]
    @State private var requesting: PrivacyPermissionKind?
    @State private var vaultError: String?
    @State private var demoLevel: Float = 0
    @State private var demoTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DesignTokens.Spacing.xxl)

            Divider()

            footer
                .padding(DesignTokens.Spacing.lg)
        }
        .frame(width: 560, height: 520)
        .background(DesignTokens.Palette.surface)
        .task { await refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermissions() }
        }
        .onChange(of: step) { _, _ in handleStepChange() }
        .onDisappear { stopDemo() }
        // Escape bypasses onboarding entirely.
        .onExitCommand { finish() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Scribe")
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Image(systemName: step.symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                Text(step.title)
                    .scribeTitle2()
                    .foregroundStyle(.primary)

                Text(step.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            stepExtras

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(step)
        .transition(stepTransition)
        .scribeAnimation(.snappy, value: step)
    }

    @ViewBuilder
    private var stepExtras: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                surfaceRow(symbol: "waveform", name: "Capture", detail: "Record & transcribe conversations")
                surfaceRow(symbol: "doc.text", name: "Notes", detail: "A Markdown notebook for your ideas")
                surfaceRow(symbol: "checklist", name: "Tasks", detail: "Keep your to-dos within reach")
            }

        case .permissions:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(PrivacyPermissionKind.onboardingKinds) { kind in
                    permissionRow(kind)
                }
                if permissions[.microphone] == .granted {
                    HStack(spacing: DesignTokens.Spacing.md) {
                        LevelMeterView(level: previewLevel, tint: accent, barCount: 16, sourceLabel: "Microphone")
                            .frame(width: 120)
                        Text("Microphone ready")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 30)
                }
                Text("Screen & system audio permission takes effect after Scribe relaunches. Scribe only captures audio, never your screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .meetings:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Picker("When a meeting starts", selection: $meetingDetectionMode) {
                    ForEach(MeetingDetectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Toggle(isOn: $captureSystemAudio) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text("Capture system audio for meetings")
                            .font(.callout.weight(.medium))
                        Text("Transcribes the people on the other end of a call, not just you.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(accent)

                Text("Change these any time in Settings → General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .vault:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text(vaultPath)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose Another Folder…", action: chooseVaultFolder)
                        .disabled(vault.isBusy)
                    if vault.isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                if let vaultError {
                    Label(vaultError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Pick an empty folder to start fresh there, or an existing notes folder (an Obsidian vault works) to use it as is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .done:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                shortcutRow(keys: ["⇧", "⌘", "R"], text: "Start or stop recording from anywhere")
                shortcutRow(keys: ["⌘", "K"], text: "Search everything and run commands")
                shortcutRow(keys: ["⌘", "N"], text: "New note")
                Text("Dictation into any app has its own shortcut in Settings → Dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ kind: PrivacyPermissionKind) -> some View {
        let state = permissions[kind] ?? .unknown
        return HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            Image(systemName: kind.systemImage)
                .font(.title3)
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(kind.title)
                    .font(.callout.weight(.medium))
                Text(kind.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if state == .granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button(state.canPrompt ? "Allow…" : "Open Settings") {
                    request(kind)
                }
                .controlSize(.small)
                .disabled(requesting != nil)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.title): \(state.label)")
    }

    private func surfaceRow(symbol: String, name: String, detail: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(name)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name). \(detail)")
    }

    private func shortcutRow(keys: [String], text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                shortcutKeycap(key)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, DesignTokens.Spacing.xs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys.joined(separator: " ")): \(text)")
    }

    private func shortcutKeycap(_ label: String) -> some View {
        Text(label)
            .font(.system(.body, weight: .semibold))
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(DesignTokens.Palette.fill(.selected, contrast: contrast))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Skip", action: finish)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityHint("Dismiss onboarding")

            Spacer()

            pageDots

            Spacer()

            HStack(spacing: DesignTokens.Spacing.sm) {
                if let previous = step.previous {
                    Button("Back") { go(to: previous) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                Button(step.isLast ? "Get Started" : "Continue") {
                    if let next = step.next { go(to: next) } else { finish() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(OnboardingStep.allCases) { page in
                Circle()
                    .fill(page == step ? accent : DesignTokens.Palette.fill(.strong, contrast: contrast))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    // MARK: - Actions

    private func go(to target: OnboardingStep) {
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            step = target
        }
    }

    private func finish() {
        OnboardingGate.markCompleted()
        stopDemo()
        isPresented = false
    }

    private func handleStepChange() {
        if step == .permissions {
            Task { await refreshPermissions() }
            startDemoIfNeeded()
        } else {
            stopDemo()
        }
    }

    private func refreshPermissions() async {
        permissions = await PrivacyPermissionProbe.states(of: PrivacyPermissionKind.onboardingKinds)
    }

    private func request(_ kind: PrivacyPermissionKind) {
        guard requesting == nil else { return }
        requesting = kind
        Task {
            await PrivacyPermissionProbe.request(kind)
            await refreshPermissions()
            requesting = nil
            if step == .permissions { startDemoIfNeeded() }
        }
    }

    // MARK: - Vault

    private var vaultPath: String {
        (vault.currentRoot ?? NotesDirectory.builtInDefault()).path
    }

    private func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.title = "Notes Folder"
        panel.message = "Choose an empty folder for new notes, or an existing notes folder to use as is."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vaultError = nil

        // Same "empty" rule as VaultCoordinator.moveVault: dotfiles don't count.
        let visible = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        Task {
            do {
                if visible.isEmpty {
                    try await vault.moveVault(to: url)
                } else {
                    let preview = try vault.previewOpen(at: url)
                    guard confirmOpen(url, toImport: preview.toImport, toRemove: preview.toRemove) else { return }
                    try await vault.openVault(at: url)
                }
            } catch {
                vaultError = error.localizedDescription
            }
        }
    }

    private func confirmOpen(_ url: URL, toImport: Int, toRemove: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Use “\(url.lastPathComponent)” for your notes?"
        var text = "Scribe will read \(toImport) note\(toImport == 1 ? "" : "s") from this folder and save new notes there."
        if toRemove > 0 {
            text += " \(toRemove) note\(toRemove == 1 ? "" : "s") in the current folder will stay on disk but no longer show in Scribe."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Use Folder")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Demo level (preview only)

    /// The live mic level when a session is running, otherwise a gentle
    /// scripted demo so the meter visibly "breathes".
    private var previewLevel: Float {
        audioManager.isRecording ? audioManager.inputLevel : demoLevel
    }

    private func startDemoIfNeeded() {
        guard !audioManager.isRecording, demoTimer == nil, !reduceMotion,
              permissions[.microphone] == .granted else { return }
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { _ in
            Task { @MainActor in
                let target = Float.random(in: 0.12...0.55)
                withAnimation(.easeInOut(duration: 0.18)) {
                    demoLevel = target
                }
            }
        }
    }

    private func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        demoLevel = 0
    }
}
