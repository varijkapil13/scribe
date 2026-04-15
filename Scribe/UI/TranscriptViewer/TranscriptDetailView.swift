import SwiftUI

/// Detailed view of a single transcript session, showing metadata, tags,
/// and all transcript segments with intelligence features (summary, action items, insights).
struct TranscriptDetailView: View {

    let session: Session
    @StateObject var viewModel: TranscriptDetailViewModel
    @State var isEditing: Bool = false
    @State var editedTitle: String = ""
    @State var editedTags: String = ""
    @State var showExportSheet: Bool = false
    @State var selectedExportFormat: ExportFormat = .markdown
    @State var selectedTab: DetailTab = .transcript

    enum DetailTab: String, CaseIterable {
        case transcript = "Transcript"
        case summary = "Summary"
        case actionItems = "Action Items"
        case insights = "Insights"
    }

    // MARK: - Initializer

    init(session: Session) {
        self.session = session
        _viewModel = StateObject(wrappedValue: TranscriptDetailViewModel(session: session))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerSection.padding()
            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Tab content
            ScrollView {
                switch selectedTab {
                case .transcript:
                    segmentsSection.padding()
                case .summary:
                    summarySection.padding()
                case .actionItems:
                    actionItemsSection.padding()
                case .insights:
                    insightsSection.padding()
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheetView(session: session, segments: viewModel.segments)
        }
        .onAppear {
            viewModel.loadSegments()
            viewModel.loadSummary()
            viewModel.loadAnalysis()
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

                Button("Summarize") {
                    Task { await viewModel.generateSummary() }
                }
                .disabled(viewModel.isGeneratingSummary || viewModel.segments.isEmpty)

                Button("Analyze") {
                    viewModel.runAnalysis()
                }
                .disabled(viewModel.isAnalyzing || viewModel.segments.isEmpty)
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

    // MARK: - Summary Section

    @ViewBuilder
    private var summarySection: some View {
        if viewModel.isGeneratingSummary {
            ProgressView("Generating summary...")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if let summary = viewModel.meetingSummary {
            VStack(alignment: .leading, spacing: 16) {
                // Executive Summary
                GroupBox("Summary") {
                    Text(summary.summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Key Decisions
                if !summary.keyDecisions.isEmpty {
                    GroupBox("Key Decisions") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(summary.keyDecisions, id: \.self) { decision in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\u{2022}")
                                    Text(decision)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Key Topics
                if !summary.keyTopics.isEmpty {
                    GroupBox("Topics") {
                        FlowLayoutView(items: summary.keyTopics) { topic in
                            Text(topic)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Follow-up Questions
                if !summary.followUpQuestions.isEmpty {
                    GroupBox("Follow-up Questions") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(summary.followUpQuestions, id: \.self) { question in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("?")
                                        .foregroundColor(.orange)
                                        .fontWeight(.bold)
                                    Text(question)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            // Empty state
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No summary yet")
                    .font(.headline)
                Button("Generate Summary") {
                    Task { await viewModel.generateSummary() }
                }
                .disabled(viewModel.segments.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }

    // MARK: - Action Items Section

    @ViewBuilder
    private var actionItemsSection: some View {
        if let summary = viewModel.meetingSummary, !summary.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.actionItems) { item in
                    HStack(alignment: .top, spacing: 12) {
                        // Checkbox (toggle completion)
                        Image(systemName: viewModel.completedActionItems.contains(item.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(viewModel.completedActionItems.contains(item.id)
                                             ? .green : .secondary)
                            .onTapGesture { viewModel.toggleActionItem(item.id) }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.description)
                                .strikethrough(viewModel.completedActionItems.contains(item.id))

                            HStack(spacing: 8) {
                                if let assignee = item.assignee {
                                    Label(assignee, systemImage: "person")
                                        .font(.caption)
                                }
                                if let deadline = item.deadline {
                                    Label(deadline, systemImage: "calendar")
                                        .font(.caption)
                                }
                                if let priority = item.priority {
                                    Text(priority.rawValue)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(priorityColor(priority).opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                    Divider()
                }
            }
        } else {
            // Empty state
            VStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No action items yet")
                    .font(.headline)
                Text("Generate a summary to extract action items")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Generate Summary") {
                    Task { await viewModel.generateSummary() }
                }
                .disabled(viewModel.segments.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }

    // MARK: - Insights Section

    @ViewBuilder
    private var insightsSection: some View {
        if viewModel.isAnalyzing {
            ProgressView("Analyzing transcript...")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if let analysis = viewModel.transcriptAnalysis {
            VStack(alignment: .leading, spacing: 16) {
                // Language
                GroupBox("Language") {
                    HStack {
                        Text(analysis.language.primaryLanguageName)
                            .font(.headline)
                        Text("(\(Int(analysis.language.confidence * 100))% confidence)")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Sentiment
                GroupBox("Sentiment") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(analysis.sentiment.label)
                                .font(.headline)
                                .foregroundColor(sentimentColor(analysis.sentiment.overallScore))
                            Text(String(format: "%.2f", analysis.sentiment.overallScore))
                                .foregroundColor(.secondary)
                        }
                        if !analysis.sentiment.perSpeaker.isEmpty {
                            Divider()
                            ForEach(Array(analysis.sentiment.perSpeaker.keys.sorted()), id: \.self) { speaker in
                                HStack {
                                    Text(speaker.capitalized)
                                    Spacer()
                                    Text(String(format: "%.2f", analysis.sentiment.perSpeaker[speaker]!))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Entities
                if !analysis.entities.isEmpty {
                    GroupBox("People & Organizations") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(ExtractedEntity.EntityType.allCases) { type in
                                let filtered = analysis.entities.filter { $0.type == type }
                                if !filtered.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(type.rawValue)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .textCase(.uppercase)
                                        ForEach(filtered) { entity in
                                            Label(entity.text, systemImage: entity.type.systemImage)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Topics
                if !analysis.topics.topics.isEmpty {
                    GroupBox("Key Topics") {
                        FlowLayoutView(items: analysis.topics.topics) { topic in
                            Text(topic)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Key Phrases
                if !analysis.keyPhrases.isEmpty {
                    GroupBox("Key Phrases") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(analysis.keyPhrases, id: \.self) { phrase in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\u{2022}")
                                    Text(phrase)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            // Empty state
            VStack(spacing: 12) {
                Image(systemName: "text.magnifyingglass")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No analysis yet")
                    .font(.headline)
                Button("Analyze Transcript") {
                    viewModel.runAnalysis()
                }
                .disabled(viewModel.segments.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }

    // MARK: - Helpers

    /// Returns a color representing the priority level.
    private func priorityColor(_ priority: ActionItem.Priority) -> Color {
        switch priority {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .blue
        }
    }

    /// Returns a color representing the sentiment score.
    private func sentimentColor(_ score: Double) -> Color {
        if score > 0.1 {
            return .green
        } else if score < -0.1 {
            return .red
        } else {
            return .primary
        }
    }
}

// MARK: - FlowLayoutView

/// A simple wrapping layout that arranges items horizontally and wraps to the
/// next line when the available width is exceeded.
private struct FlowLayoutView<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    @State private var totalHeight: CGFloat = .zero

    var body: some View {
        GeometryReader { geometry in
            self.generateContent(in: geometry)
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in geometry: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.self) { item in
                content(item)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                    .alignmentGuide(.leading) { dimension in
                        if abs(width - dimension.width) > geometry.size.width {
                            width = 0
                            height -= dimension.height
                        }
                        let result = width
                        if item == items.last {
                            width = 0
                        } else {
                            width -= dimension.width
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item == items.last {
                            height = 0
                        }
                        return result
                    }
            }
        }
        .background(viewHeightReader($totalHeight))
    }

    private func viewHeightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { geometry -> Color in
            let rect = geometry.frame(in: .local)
            DispatchQueue.main.async {
                binding.wrappedValue = rect.size.height
            }
            return .clear
        }
    }
}
