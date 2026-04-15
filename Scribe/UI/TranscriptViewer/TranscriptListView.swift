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
            .onChange(of: searchText) { newValue in
                viewModel.search(query: newValue)
            }
            .navigationTitle("Transcripts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        } detail: {
            if let sessionID = selectedSessionID,
               let session = viewModel.filteredSessions.first(where: { $0.id == sessionID }) {
                TranscriptDetailView(session: session)
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
