import SwiftUI
import Combine

/// Browsable, searchable library of every recording session — the transcript
/// archive. Reachable from the Capture surface and ⌘K; rows deep-link to the
/// transcript reader via `.session(id)`. Closes the gap where past meetings
/// were only reachable through their owning note.
@MainActor
final class TranscriptArchiveViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var query: String = ""

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

    /// Sessions grouped into relative date buckets (most-recent first).
    var groups: [(title: String, sessions: [Session])] {
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
            let comps = cal.dateComponents([.year, .month], from: date)
            let key = 1000 - ((comps.year ?? 0) * 12 + (comps.month ?? 0)) // older = larger
            return (key, Self.monthFormatter.string(from: date))
        }
        for session in filtered {
            let (key, title) = bucketIndex(for: session.createdAt)
            if let i = buckets.firstIndex(where: { $0.key == key }) {
                buckets[i].items.append(session)
            } else {
                buckets.append((key, title, [session]))
            }
        }
        return buckets.sorted { $0.key < $1.key }.map { ($0.title, $0.items) }
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
                List {
                    ForEach(vm.groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.sessions) { session in
                                Button { onNavigate(session.id) } label: {
                                    SessionArchiveRow(session: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Recordings")
        .searchable(text: $vm.query, prompt: "Search recordings")
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }
}

/// One row in the recordings archive: title, relative date, duration.
private struct SessionArchiveRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(session.title.isEmpty ? "Untitled recording" : session.title)
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(session.createdAt, format: .dateTime.month().day().hour().minute())
                    if let duration = durationLabel {
                        Text("·")
                        Text(duration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .contentShape(Rectangle())
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
