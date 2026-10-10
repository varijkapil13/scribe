// Scribe/UI/Translation/LiveCaptionTranslationBar.swift
import SwiftUI
import Translation

/// Optional live-caption translation under the live transcript: when on,
/// the latest captions are translated on-device (Apple's Translation
/// framework) into the chosen language. Display only — nothing is stored.
@MainActor
struct LiveCaptionTranslationBar: View {
    let segments: [TranscriptionSegment]

    @AppStorage(LiveCaptionTranslationModel.enabledKey) private var enabled = false
    @StateObject private var model = LiveCaptionTranslationModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Translate captions", isOn: $enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if enabled {
                    Picker("Into", selection: $model.targetIdentifier) {
                        if model.languages.isEmpty {
                            Text("Loading…").tag(model.targetIdentifier)
                        }
                        ForEach(model.languages, id: \.minimalIdentifier) { language in
                            Text(ScribeTranslationRunner.displayName(for: language)).tag(language.minimalIdentifier)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
            }
            if enabled {
                ForEach(model.lines) { line in
                    Text(line.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = model.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .task(id: enabled) {
            model.setEnabled(enabled)
            if enabled { await model.loadLanguages() }
        }
        .onChange(of: segments) { _, newValue in
            model.captionsChanged(newValue)
        }
        .onChange(of: model.targetIdentifier) { _, _ in
            model.targetChanged()
        }
        .modifier(ScribeTranslationHost(
            configuration: model.configuration,
            texts: model.pendingTexts,
            onProgress: { _ in },
            onFinish: { [model = self.model] outcome in model.finish(outcome) }
        ))
    }
}

/// Debounces caption changes and translates the latest few captions.
@MainActor
final class LiveCaptionTranslationModel: ObservableObject {

    nonisolated static let enabledKey = "liveCaptionTranslationEnabled"
    nonisolated static let targetKey = "liveCaptionTranslationTarget"
    /// Captions shown (and translated) at once.
    nonisolated static let visibleCount = 3

    struct Line: Identifiable, Equatable {
        let id: UUID
        var text: String
    }

    @Published private(set) var languages: [Locale.Language] = []
    @Published var targetIdentifier: String {
        didSet { UserDefaults.standard.set(targetIdentifier, forKey: Self.targetKey) }
    }
    @Published private(set) var lines: [Line] = []
    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published private(set) var pendingTexts: [String] = []
    @Published private(set) var errorMessage: String?

    private var isEnabled = false
    private var isRunning = false
    private var latest: [TranscriptionSegment] = []
    private var running: [TranscriptionSegment] = []
    /// segment id → (source text, translation)
    private var cache: [UUID: (source: String, translation: String)] = [:]
    private var debounce: Task<Void, Never>?

    init() {
        targetIdentifier = UserDefaults.standard.string(forKey: Self.targetKey) ?? ""
    }

    private var target: Locale.Language? {
        languages.first { $0.minimalIdentifier == targetIdentifier }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            debounce?.cancel()
            configuration = nil
            lines = []
            cache = [:]
            running = []
            isRunning = false
        }
    }

    func loadLanguages() async {
        guard languages.isEmpty else { return }
        languages = await ScribeTranslationRunner.supportedLanguages()
        if target == nil {
            let preferred = Locale.current.language.minimalIdentifier
            targetIdentifier = languages.first { $0.minimalIdentifier == preferred }?.minimalIdentifier
                ?? languages.first?.minimalIdentifier ?? ""
        }
        scheduleRun()
    }

    func targetChanged() {
        cache = [:]
        // Dropping the configuration cancels a run in flight; its outcome is
        // ignored (see `finish`).
        configuration = nil
        running = []
        isRunning = false
        scheduleRun()
    }

    func captionsChanged(_ segments: [TranscriptionSegment]) {
        latest = Array(segments.suffix(Self.visibleCount))
        refreshLines()
        scheduleRun()
    }

    /// Waits for the captions to settle, then translates what changed.
    private func scheduleRun() {
        guard isEnabled else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            self?.runIfNeeded()
        }
    }

    private func runIfNeeded() {
        guard isEnabled, !isRunning, let target else { return }
        let stale = latest.filter { segment in
            !segment.text.isEmpty && cache[segment.id]?.source != segment.text
        }
        guard !stale.isEmpty else { return }
        running = stale
        pendingTexts = stale.map(\.text)
        isRunning = true
        errorMessage = nil
        if configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: nil, target: target)
        }
    }

    func finish(_ outcome: ScribeTranslationOutcome) {
        // A run abandoned by a target change or by switching off.
        guard isRunning, !running.isEmpty else { return }
        isRunning = false
        switch outcome {
        case .finished(let translations):
            for (index, segment) in running.enumerated() where index < translations.count {
                cache[segment.id] = (segment.text, translations[index])
            }
        case .failed(let message):
            errorMessage = "Couldn’t translate captions: \(message)"
        }
        running = []
        refreshLines()
        // Captions may have moved on while translating.
        if errorMessage == nil { scheduleRun() }
    }

    private func refreshLines() {
        lines = latest.compactMap { segment in
            guard let cached = cache[segment.id] else { return nil }
            return Line(id: segment.id, text: cached.translation)
        }
    }
}
