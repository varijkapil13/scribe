import SwiftUI

// MARK: - Model

/// Bookmarked moments of a finished session, for the transcript reader
/// (Summary tab "Highlights" + markers on the playback timeline).
@MainActor
final class SessionHighlightsModel: ObservableObject {

    @Published private(set) var bookmarks: [SessionBookmark] = []
    private(set) var sessionId: String?
    private let store: SessionBookmarkStore

    init(store: SessionBookmarkStore) {
        self.store = store
    }

    func load(sessionId: String) {
        self.sessionId = sessionId
        bookmarks = (try? store.fetch(sessionId: sessionId)) ?? []
    }

    func rename(_ bookmark: SessionBookmark, to label: String) {
        guard let id = bookmark.id, let sessionId else { return }
        try? store.updateLabel(id: id, label: label)
        load(sessionId: sessionId)
    }

    func delete(_ bookmark: SessionBookmark) {
        guard let id = bookmark.id, let sessionId else { return }
        try? store.delete(id: id)
        load(sessionId: sessionId)
    }

    /// Bookmark at a playback position (milliseconds).
    func add(atMs offsetMs: Int) {
        guard let sessionId else { return }
        _ = try? store.add(sessionId: sessionId, offsetMs: offsetMs, label: nil, createdAt: Date())
        load(sessionId: sessionId)
    }

    /// Plain-text highlight lines (no markdown emphasis) for email / sharing.
    func plainLines(segments: [Segment], speakerName: (Segment) -> String) -> [String] {
        let sortedSegments = segments.sorted { $0.startMs < $1.startMs }
        return SessionBookmarkFormatter.sorted(bookmarks).map {
            SessionBookmarkFormatter.highlightLine($0, segments: sortedSegments, speakerName: speakerName)
                .replacingOccurrences(of: "**", with: "")
        }
    }
}

// MARK: - Highlights section

/// "Highlights" card listing bookmarked moments with their transcript
/// context. Timestamps seek the player when the session has audio.
struct SessionHighlightsSection: View {
    @ObservedObject var model: SessionHighlightsModel
    let segments: [Segment]
    let speakerName: (Segment) -> String
    /// Seek-and-play, or nil without audio.
    let onPlay: ((Int) -> Void)?

    @State private var renaming: SessionBookmark?
    @State private var renameText = ""

    var body: some View {
        if !model.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Highlights")
                    .font(DesignTokens.Typography.section)
                ForEach(model.bookmarks, id: \.self) { bookmark in
                    row(bookmark)
                }
            }
            .accentCard(tint: .yellow)
            .alert("Label this moment", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Label", text: $renameText)
                Button("Save") {
                    if let bookmark = renaming { model.rename(bookmark, to: renameText) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private func row(_ bookmark: SessionBookmark) -> some View {
        let stamp = SessionBookmarkFormatter.shortTimestamp(ms: bookmark.offsetMs)
        let sortedSegments = segments
        let context = SessionBookmarkFormatter.contextIndex(offsetMs: bookmark.offsetMs, in: sortedSegments)
            .map { sortedSegments[$0] }
        return HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            if let onPlay {
                Button(stamp) { onPlay(bookmark.offsetMs) }
                    .buttonStyle(.link)
                    .font(DesignTokens.Typography.timestamp)
                    .help("Play from \(stamp)")
            } else {
                Text(stamp)
                    .font(DesignTokens.Typography.timestamp)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let label = bookmark.trimmedLabel {
                    Text(label).font(.callout.weight(.medium))
                }
                if let context {
                    Text("\(speakerName(context)): “\(SessionBookmarkFormatter.quote(context.text))”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if bookmark.trimmedLabel == nil {
                    Text("Marked moment").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            Button("Label…") {
                renameText = bookmark.label ?? ""
                renaming = bookmark
            }
            Button("Delete", role: .destructive) { model.delete(bookmark) }
        }
    }
}

// MARK: - Timeline markers

private struct PlaybackBookmarkOffsetsKey: EnvironmentKey {
    static let defaultValue: [Int] = []
}

extension EnvironmentValues {
    /// Bookmark offsets (ms) drawn as markers on the session audio player's
    /// timeline. Set by the transcript reader.
    var playbackBookmarkOffsets: [Int] {
        get { self[PlaybackBookmarkOffsetsKey.self] }
        set { self[PlaybackBookmarkOffsetsKey.self] = newValue }
    }
}

/// Thin ticks over a slider track, one per bookmark. Purely decorative (no
/// hit testing) so scrubbing still works; the Highlights list seeks.
struct BookmarkMarkersOverlay: View {
    let offsetsMs: [Int]
    let durationSeconds: Double
    /// Approximate inset of the slider track from the control's edges.
    var trackInset: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width - trackInset * 2)
            ForEach(Array(offsetsMs.enumerated()), id: \.offset) { _, offset in
                if let fraction = SessionBookmarkFormatter.markerFraction(offsetMs: offset, durationSeconds: durationSeconds) {
                    Capsule()
                        .fill(Color.yellow)
                        .frame(width: 3, height: 12)
                        .position(x: trackInset + width * CGFloat(fraction), y: proxy.size.height / 2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
