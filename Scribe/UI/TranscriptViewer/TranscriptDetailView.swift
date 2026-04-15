import SwiftUI

/// Detailed view of a single transcript session, showing metadata, tags,
/// and all transcript segments.
struct TranscriptDetailView: View {

    let session: Session
    @StateObject var viewModel: TranscriptDetailViewModel
    @State var isEditing: Bool = false
    @State var editedTitle: String = ""
    @State var editedTags: String = ""
    @State var showExportSheet: Bool = false
    @State var selectedExportFormat: ExportFormat = .markdown

    // MARK: - Initializer

    init(session: Session) {
        self.session = session
        _viewModel = StateObject(wrappedValue: TranscriptDetailViewModel(session: session))
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                Divider()
                segmentsSection
            }
            .padding()
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheetView(session: session, segments: viewModel.segments)
        }
        .onAppear {
            viewModel.loadSegments()
            editedTitle = session.title
            editedTags = session.tags.joined(separator: ", ")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    TextField("Title", text: $editedTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("Tags (comma-separated)", text: $editedTags)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(session.title)
                        .font(.title)
                        .bold()

                    if !session.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(session.tags, id: \.self) { tag in
                                Text(tag)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.2))
                                    .cornerRadius(4)
                                    .font(.caption)
                            }
                        }
                    }
                }

                HStack(spacing: 4) {
                    Text(session.createdAt, style: .date)
                    Text("\u{00b7}")
                    Text(viewModel.formattedDuration)
                    if let lang = session.language {
                        Text("\u{00b7}")
                        Text(lang.uppercased())
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }

            Spacer()

            VStack(spacing: 8) {
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing {
                        viewModel.updateSessionTitle(editedTitle)
                        let tags = editedTags
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        viewModel.updateSessionTags(tags)
                    }
                    isEditing.toggle()
                }

                Button("Export") {
                    showExportSheet = true
                }
            }
        }
    }

    // MARK: - Segments

    @ViewBuilder
    private var segmentsSection: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(viewModel.segments) { segment in
                SegmentView(segment: segment)
            }
        }
    }
}
