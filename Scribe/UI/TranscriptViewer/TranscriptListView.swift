import SwiftUI

/// Main transcript history view showing all past sessions in a split layout.
struct TranscriptListView: View {

    @StateObject var viewModel = TranscriptListViewModel()
    @State var searchText: String = ""
    @State var selectedSessionID: String? = nil

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSessionID) {
                ForEach(viewModel.filteredSessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRowView(session: session)
                    }
                }
                .onDelete { indexSet in
                    viewModel.deleteSessions(at: indexSet)
                }
            }
            .searchable(text: $searchText)
            .onChange(of: searchText) { _, newValue in
                viewModel.search(query: newValue)
            }
            .navigationTitle("Transcripts")
        } detail: {
            if let sessionID = selectedSessionID,
               let session = viewModel.filteredSessions.first(where: { $0.id == sessionID }) {
                // Bind view identity to session.id so SwiftUI creates a fresh
                // TranscriptDetailViewModel (which is a @StateObject) when the
                // user picks a different session — otherwise the first session
                // viewed would be shown for every subsequent selection.
                TranscriptDetailView(session: session)
                    .id(session.id)
            } else {
                Text("Select a transcript")
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            viewModel.loadSessions()
        }
    }
}
