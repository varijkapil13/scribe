import Foundation
import Combine

/// ViewModel that drives the transcript list, providing session data,
/// filtering, and search capabilities.
final class TranscriptListViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var sessions: [Session] = []
    @Published var filteredSessions: [Session] = []
    @Published var searchResults: [(Session, [Segment])] = []
    @Published var isSearching: Bool = false

    // MARK: - Dependencies

    private let store: TranscriptStore

    // MARK: - Initializer

    init(store: TranscriptStore = TranscriptStore()) {
        self.store = store
    }

    // MARK: - Public Methods

    /// Fetches all sessions from the store and updates published properties.
    func loadSessions() {
        do {
            let allSessions = try store.fetchAllSessions()
            sessions = allSessions
            filteredSessions = allSessions
        } catch {
            sessions = []
            filteredSessions = []
        }
    }

    /// Filters sessions by the given query. When the query is empty all
    /// sessions are shown; otherwise FTS5 full-text search is used.
    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            isSearching = false
            searchResults = []
            filteredSessions = sessions
            return
        }

        isSearching = true

        do {
            let results = try store.searchTranscripts(query: trimmed)
            searchResults = results
            filteredSessions = results.map { $0.0 }
        } catch {
            searchResults = []
            filteredSessions = sessions
        }

        isSearching = false
    }

    /// Deletes sessions at the given index set offsets and reloads the list.
    func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            guard filteredSessions.indices.contains(index) else { continue }
            let session = filteredSessions[index]
            try? store.deleteSession(id: session.id)
        }
        loadSessions()
    }

    /// Deletes a single session and reloads the list.
    func deleteSession(_ session: Session) {
        try? store.deleteSession(id: session.id)
        loadSessions()
    }
}
