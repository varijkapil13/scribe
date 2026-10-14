import SwiftUI
import Combine

/// Browsable, searchable library of every recording session — the transcript
/// archive. Reachable from the Capture surface and ⌘K; rows deep-link to the
/// transcript reader via `.session(id)`. Closes the gap where past meetings
/// were only reachable through their owning note.
@MainActor
final class TranscriptArchiveViewModel: ObservableObject {
    @Published var sessions: [Session] = [] { didSet { regroup() } }
    @Published var query: String = "" { didSet { regroup() } }
    @Published private(set) var groups: [(title: String, sessions: [Session])] = []

    private let store: TranscriptStore
    private var cancellables = Set<AnyCancellable>()

    init(store: TranscriptStore = .shared) { self.store = store }

    func start() {
        reload()
        // Re-fetch when a session is saved/updated or recording stops.
        NotificationCenter.default.publisher(for: .scribeSessionUpdated)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func stop() { cancellables.removeAll() }

    func reload() {
        sessions = ((try? store.fetchAllSessions()) ?? [])
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var filtered: [Session] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { $0.title.lowercased().contains(q) }
    }

    private func regroup() {
        groups = Perf.measure("archive.group") { computeGroups() }
    }

    /// Sessions grouped into relative date buckets (most-recent first).
    private func computeGroups() -> [(title: String, sessions: [Session])] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(key: Int, title: String, items: [Session])] = []
        func bucketIndex(for date: Date) -> (Int, String) {
            if cal.isDateInToday(date) { return (0, "Today") }
            if cal.isDateInYesterday(date) { return (1, "Yesterday") }
            if let week = cal.dateInterval(of: .weekOfYear, for: now), week.contains(date) {
                return (2, "Earlier this week")
            }
            if let month = cal.dateInterval(of: .month, for: now), month.contains(date) {
                return (3, "Earlier this month")
            }
            // Previous months: key grows with how many months back the date
            // is, so the newest previous month sorts right after the named
            // buckets and older months follow. (The old `1000 - year*12+month`
            // formula produced large NEGATIVE keys, which sorted the whole
            // month range ABOVE Today / this week / this month.)
            let comps = cal.dateComponents([.year, .month], from: date)
            let nowComps = cal.dateComponents([.year, .month], from: now)
            let monthsAgo = ((nowComps.year ?? 0) * 12 + (nowComps.month ?? 0))
                          - ((comps.year ?? 0) * 12 + (comps.month ?? 0))
            return (3 + max(1, monthsAgo), Self.monthFormatter.string(from: date))
        }
        for session in filtered {
            let (key, title) = bucketIndex(for: session.createdAt)
            if let i = buckets.firstIndex(where: { $0.key == key }) {
                buckets[i].items.append(session)
            } else {
                buckets.append((key, title, [session]))
            }
        }
        // Groups newest-first (ascending key), and newest-first within each
        // group regardless of insertion order.
        return buckets
            .sorted { $0.key < $1.key }
            .map { ($0.title, $0.items.sorted { $0.createdAt > $1.createdAt }) }
    }

    nonisolated static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()
}

struct TranscriptArchiveView: View {
    @StateObject private var vm = TranscriptArchiveViewModel()
    /// Navigate to a session's transcript reader.
    var onNavigate: (String) -> Void

    var body: some View {
        Group {
            if vm.sessions.isEmpty {
                EmptyStateView(
                    systemImage: "waveform",
                    title: "No recordings yet",
                    message: "Press Record in the toolbar (or ⇧⌘R from anywhere) and your meetings will collect here."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        QuietListHeader(title: "Recordings", count: countLabel)
                            .padding(.bottom, DesignTokens.QuietList.sectionSpacing)
                        ForEach(vm.groups, id: \.title) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    SessionArchiveRow(session: session) { onNavigate(session.id) }
                                }
                            } header: {
                                HStack(spacing: DesignTokens.Spacing.sm) {
                                    Text(group.title)
                                    Text("\(group.sessions.count)").monospacedDigit()
                                }
                                .quietListSectionHeader()
                                .padding(.horizontal, DesignTokens.Spacing.sm)
                                .padding(.top, DesignTokens.QuietList.sectionSpacing)
                                .padding(.bottom, DesignTokens.Spacing.xs)
                                .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                    .padding(.horizontal, DesignTokens.QuietList.gutter)
                    .padding(.vertical, DesignTokens.Spacing.xl)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(DesignTokens.Palette.ground)
        .navigationTitle("Recordings")
        .searchable(text: $vm.query, prompt: "Search recordings")
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    private var countLabel: String {
        let total = vm.groups.reduce(0) { $0 + $1.sessions.count }
        return total == 1 ? "1 recording" : "\(total) recordings"
    }
}

/// One row in the recordings archive: title, relative date, duration.
private struct SessionArchiveRow: View {
    let session: Session
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .frame(width: 16)
                Text(session.title.isEmpty ? "Untitled recording" : session.title)
                    .font(DesignTokens.QuietList.rowTitleFont)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.Spacing.md)
                MeetingOriginBadge(sessionId: session.id)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if let duration = durationLabel {
                        Text(duration)
                    }
                    Text(session.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
                .font(DesignTokens.QuietList.rowMetaFont)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(minHeight: DesignTokens.QuietList.rowHeight)
            .quietListRowBackground(selected: false, hovered: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.title.isEmpty ? "Untitled recording" : session.title)
        .accessibilityHint("Opens this recording's transcript")
    }

    private var durationLabel: String? {
        guard let seconds = session.durationSeconds, seconds > 0 else { return nil }
        let minutes = seconds / 60
        if minutes < 1 { return "\(seconds)s" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
