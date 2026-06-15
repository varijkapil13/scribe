import SwiftUI

/// Detailed view of a single transcript session, showing metadata, tags,
/// and all transcript segments with intelligence features (summary, action items, insights).
struct TranscriptDetailView: View {

    @StateObject var viewModel: TranscriptDetailViewModel
    @State var isEditing: Bool = false
    @State var editedTitle: String = ""
    @State var editedTags: String = ""
    @State var showExportSheet: Bool = false
    @State var selectedExportFormat: ExportFormat = .markdown
    @State var selectedTab: DetailTab = .transcript
    @State var showMoveSheet: Bool = false
    @State var openedTask: TodoTask?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @FocusState private var focusedTab: DetailTab?

    private var session: Session { viewModel.session }

    enum DetailTab: String, CaseIterable {
        case transcript = "Transcript"
        case summary = "Summary"
        case actionItems = "Action Items"
        case insights = "Insights"

        var systemImage: String {
            switch self {
            case .transcript:  return "text.alignleft"
            case .summary:     return "sparkles"
            case .actionItems: return "checklist"
            case .insights:    return "chart.bar.xaxis"
            }
        }
    }

    // MARK: - Initializer

    init(session: Session) {
        _viewModel = StateObject(wrappedValue: TranscriptDetailViewModel(session: session))
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.top, DesignTokens.Spacing.xl)
                .padding(.bottom, DesignTokens.Spacing.lg)

            Divider()

            tabPicker
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.vertical, DesignTokens.Spacing.md)

            ScrollView {
                Group {
                    switch selectedTab {
                    case .transcript:  transcriptSection
                    case .summary:     summarySection
                    case .actionItems: actionItemsSection
                    case .insights:    insightsSection
                    }
                }
                .padding(DesignTokens.Spacing.xl)
            }
        }
        .frame(minWidth: 600, minHeight: 480)
        .sheet(isPresented: $showExportSheet) {
            ExportSheetView(session: session, segments: viewModel.segments)
        }
        .sheet(isPresented: $showMoveSheet) {
            MoveSegmentsSheet(viewModel: viewModel) {
                showMoveSheet = false
            }
        }
        .sheet(item: $openedTask, onDismiss: {
            // Refresh once the editor closes — the task may have been deleted
            // (so the row should drop the green "Open task" state) or
            // duplicated (still converted, no change needed).
            viewModel.refreshConvertedActionItems()
        }) { task in
            TaskInspectorSheet(task: task) { openedTask = nil }
        }
        .onAppear {
            viewModel.loadSegments()
            viewModel.loadSummary()
            viewModel.loadAnalysis()
            viewModel.refreshIntelligenceAvailability()
            editedTitle = session.title
            editedTags = session.tags.joined(separator: ", ")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if isEditing {
                TextField("Title", text: $editedTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title2, weight: .semibold))

                TextField("Tags (comma-separated)", text: $editedTags)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)

                HStack {
                    Button("Cancel") {
                        editedTitle = session.title
                        editedTags = session.tags.joined(separator: ", ")
                        isEditing = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])

                    Spacer()

                    Button("Save") {
                        viewModel.updateSessionTitle(editedTitle)
                        let tags = editedTags
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        viewModel.updateSessionTags(tags)
                        isEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            } else {
                Text("TRANSCRIPT")
                    .eyebrowStyle()

                // Muted breadcrumb so the user knows where they landed after a
                // ⌘K / deep-link jump.
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Recordings")
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                    Text(session.title.isEmpty ? "Untitled Session" : session.title)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location: Recordings, \(session.title.isEmpty ? "Untitled Session" : session.title)")

                HStack(alignment: .firstTextBaseline) {
                    Text(session.title.isEmpty ? "Untitled Session" : session.title)
                        .font(DesignTokens.Typography.title1)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Spacer()

                    Button {
                        isEditing = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Rename session and edit tags")
                }

                HStack(spacing: DesignTokens.Spacing.md) {
                    Label(formattedDate, systemImage: "calendar")
                    Text("·").foregroundStyle(.tertiary)
                    Label(viewModel.formattedDuration, systemImage: "waveform")
                        .monospacedDigit()
                    if let lang = session.language?.uppercased(), !lang.isEmpty, lang != "AUTO" {
                        Text("·").foregroundStyle(.tertiary)
                        Label(lang, systemImage: "globe")
                    }
                    if !viewModel.segments.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Label("\(viewModel.segments.count) segments", systemImage: "text.alignleft")
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if !session.tags.isEmpty {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        ForEach(session.tags, id: \.self) { tag in
                            TagChip(text: tag, tint: .secondary)
                        }
                    }
                }

                transcriptActionBar
            }
        }
    }

    /// In-body action bar (Summarize / Analyze / Export / Select). Lives in the
    /// header rather than `.toolbar` so it renders in EVERY presentation
    /// context — the "Open transcript" sheet AND the detail-pane `.session(id)`
    /// route, where toolbar items get dropped competing with the window's own
    /// toolbar.
    @ViewBuilder
    private var transcriptActionBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if viewModel.isSelecting {
                Text("\(viewModel.selectedSegmentIds.count) selected")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button {
                    viewModel.loadMoveTargets()
                    showMoveSheet = true
                } label: { Label("Move To…", systemImage: "arrow.right.doc.on.clipboard") }
                    .disabled(viewModel.selectedSegmentIds.isEmpty)
                Button { viewModel.toggleSelectMode() } label: {
                    Label("Done", systemImage: "xmark.circle")
                }
                Spacer()
            } else {
                Button { Task { await viewModel.generateSummary() } } label: {
                    Label("Summarize", systemImage: "sparkles")
                }
                .disabled(viewModel.isGeneratingSummary
                          || viewModel.segments.isEmpty
                          || !viewModel.intelligenceAvailability.isAvailable)
                .help(viewModel.intelligenceAvailability.isAvailable
                      ? "Generate an AI summary with Apple Intelligence"
                      : "Apple Intelligence is unavailable on this Mac")

                Button { viewModel.runAnalysis() } label: {
                    Label("Analyze", systemImage: "chart.bar.xaxis")
                }
                .disabled(viewModel.isAnalyzing || viewModel.segments.isEmpty)
                .help("Extract entities, topics, and sentiment")

                Spacer()

                Button { viewModel.toggleSelectMode() } label: {
                    Label("Select", systemImage: "checklist")
                }
                .disabled(viewModel.segments.isEmpty)
                .help("Select segments to move into another transcript")

                Button { showExportSheet = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export transcript to Markdown, plain text, or JSON")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.top, DesignTokens.Spacing.xs)
    }

    private var formattedDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(session.createdAt) {
            return "Today at " + session.createdAt.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(session.createdAt) {
            return "Yesterday at " + session.createdAt.formatted(date: .omitted, time: .shortened)
        }
        return session.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Tab Picker

    /// Editorial underlined tabs — feel closer to a magazine table-of-contents
    /// than an iOS segmented control. The active tab's label is bolder and
    /// backed by a thin moving underline that animates between positions.
    private var tabPicker: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                tabButton(for: tab)
            }
            Spacer()
        }
        // Left/Right arrows move between tabs when any tab owns keyboard focus,
        // matching the VoiceOver tab-bar idiom. `selectedTab` follows focus so
        // the underline + content track together.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript sections")
        .onKeyPress(.leftArrow) { moveTabFocus(by: -1) }
        .onKeyPress(.rightArrow) { moveTabFocus(by: 1) }
    }

    private func tabButton(for tab: DetailTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectTab(tab)
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: tab.systemImage)
                        .font(.system(.caption, weight: .semibold))
                    Text(tab.rawValue)
                        .font(.system(.callout, weight: isSelected ? .semibold : .regular))
                }
                .foregroundStyle(isSelected ? Color.primary : .secondary)

                Rectangle()
                    .fill(isSelected ? Color.accentColor : .clear)
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .focusable()
        .focused($focusedTab, equals: tab)
        .readerAnimation(selectedTab, reduceMotion: reduceMotion)
        // Tab semantics: it's a selectable header for the section below.
        .accessibilityLabel(tab.rawValue)
        .accessibilityHint("Shows the \(tab.rawValue.lowercased()) section")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isHeader] : .isHeader)
    }

    /// Selects a tab, gating the underline animation on Reduce Motion, and
    /// moves keyboard focus to it so arrow traversal continues from there.
    private func selectTab(_ tab: DetailTab) {
        if let animation = ReaderStyle.spring(reduceMotion: reduceMotion) {
            withAnimation(animation) { selectedTab = tab }
        } else {
            selectedTab = tab
        }
        focusedTab = tab
    }

    /// Moves selection/focus by `offset` tabs, clamped to the ends. Returns a
    /// `KeyPress.Result` so SwiftUI knows whether we handled the arrow.
    private func moveTabFocus(by offset: Int) -> KeyPress.Result {
        let tabs = DetailTab.allCases
        guard let current = tabs.firstIndex(of: focusedTab ?? selectedTab) else { return .ignored }
        let next = current + offset
        guard tabs.indices.contains(next) else { return .ignored }
        selectTab(tabs[next])
        return .handled
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptSection: some View {
        if viewModel.segments.isEmpty {
            EmptyStateView(
                systemImage: "text.alignleft",
                title: "No transcript yet",
                message: "This session didn't capture any speech. Start a new recording to see segments here."
            )
            .frame(minHeight: 280)
        } else {
            LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(viewModel.segments) { segment in
                    SegmentView(
                        segment: segment,
                        isSelecting: viewModel.isSelecting,
                        isSelected: segment.id.map { viewModel.selectedSegmentIds.contains($0) } ?? false,
                        onToggleSelection: {
                            if let id = segment.id {
                                viewModel.toggleSegmentSelection(id)
                            }
                        }
                    )
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        if viewModel.isGeneratingSummary {
            GenerationSkeleton(
                title: "Generating summary with Apple Intelligence…",
                lineWidths: [1.0, 0.94, 0.7, 0.98, 0.62, 0.85]
            )
        } else if case .unavailable(let reason) = viewModel.intelligenceAvailability,
                  viewModel.meetingSummary == nil {
            IntelligenceUnavailableView(reason: reason)
                .frame(minHeight: 280)
        } else if let error = viewModel.summaryError {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Summary failed")
                        .font(.system(.headline, weight: .semibold))
                }
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Try Again") {
                    Task { await viewModel.generateSummary() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.segments.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accentCard(tint: .orange)
        } else if let summary = viewModel.meetingSummary {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("Executive Summary")
                        .font(.system(.headline, weight: .semibold))
                    Text(summary.summary)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .accentCard(tint: .accentColor)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Executive summary. \(summary.summary)")

                if !summary.keyDecisions.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        Text("Key Decisions")
                            .font(.system(.headline, weight: .semibold))
                        ForEach(summary.keyDecisions, id: \.self) { decision in
                            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .padding(.top, 3)
                                Text(decision)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .accentCard(tint: .green)
                }

                if !summary.keyTopics.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        Text("Topics Discussed")
                            .font(.system(.headline, weight: .semibold))
                        FlowLayoutView(items: summary.keyTopics) { topic in
                            TagChip(text: topic, tint: .accentColor)
                        }
                    }
                    .accentCard(tint: .purple)
                }

                if !summary.followUpQuestions.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        Text("Follow-Up Questions")
                            .font(.system(.headline, weight: .semibold))
                        ForEach(summary.followUpQuestions, id: \.self) { question in
                            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                                Image(systemName: "questionmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .padding(.top, 3)
                                Text(question)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .accentCard(tint: .orange)
                }
            }
            .modifier(RevealModifier(token: viewModel.summaryRevealToken, reduceMotion: reduceMotion))
        } else {
            EmptyStateView(
                systemImage: "sparkles",
                title: "No summary yet",
                message: "Generate an AI summary to see the executive overview, key decisions, and follow-up questions.",
                actionTitle: viewModel.segments.isEmpty ? nil : "Generate Summary",
                action: viewModel.segments.isEmpty ? nil : { Task { await viewModel.generateSummary() } }
            )
            .frame(minHeight: 280)
        }
    }

    // MARK: - Action Items

    @ViewBuilder
    private var actionItemsSection: some View {
        if viewModel.isGeneratingSummary {
            GenerationSkeleton(
                title: "Extracting action items…",
                lineWidths: [0.85, 0.6, 0.92, 0.5]
            )
        } else if let summary = viewModel.meetingSummary, !summary.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("\(summary.actionItems.count) action item\(summary.actionItems.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, DesignTokens.Spacing.xs)
                    .accessibilityAddTraits(.isHeader)

                ForEach(summary.actionItems) { item in
                    ActionItemRow(
                        item: item,
                        isCompleted: viewModel.completedActionItems.contains(item.id),
                        isConverted: viewModel.convertedActionItems.contains(item.id),
                        onToggle: { viewModel.toggleActionItem(item.id) },
                        onConvert: {
                            if let task = viewModel.convertActionItemToTask(item) {
                                openedTask = task
                            }
                        }
                    )
                }
            }
            .modifier(RevealModifier(token: viewModel.summaryRevealToken, reduceMotion: reduceMotion))
        } else if case .unavailable(let reason) = viewModel.intelligenceAvailability {
            IntelligenceUnavailableView(reason: reason)
                .frame(minHeight: 280)
        } else {
            EmptyStateView(
                systemImage: "checklist",
                title: "No action items yet",
                message: "Action items are extracted when you generate a summary. They'll appear here with assignees, deadlines, and priority.",
                actionTitle: viewModel.segments.isEmpty ? nil : "Generate Summary",
                action: viewModel.segments.isEmpty ? nil : { Task { await viewModel.generateSummary() } }
            )
            .frame(minHeight: 280)
        }
    }

    // MARK: - Insights

    @ViewBuilder
    private var insightsSection: some View {
        if viewModel.isAnalyzing {
            GenerationSkeleton(
                title: "Analyzing transcript…",
                lineWidths: [0.7, 0.95, 0.55, 0.88]
            )
        } else if let error = viewModel.analysisError, viewModel.transcriptAnalysis == nil {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Analysis failed")
                        .font(.system(.headline, weight: .semibold))
                }
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Try Again") {
                    viewModel.runAnalysis()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.segments.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accentCard(tint: .orange)
        } else if let analysis = viewModel.transcriptAnalysis {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                InsightCard(
                    tint: .blue,
                    icon: "globe",
                    title: "Language"
                ) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(analysis.language.primaryLanguageName)
                            .font(.system(.title3, weight: .semibold))
                        Text("\(Int(analysis.language.confidence * 100))% confidence")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                InsightCard(
                    tint: sentimentTint(analysis.sentiment.overallScore),
                    icon: "heart.text.square",
                    title: "Sentiment"
                ) {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                        Text(analysis.sentiment.label)
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(sentimentTint(analysis.sentiment.overallScore))
                        Text(String(format: "%.2f", analysis.sentiment.overallScore))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !analysis.sentiment.perSpeaker.isEmpty {
                        Divider().padding(.vertical, DesignTokens.Spacing.xs)
                        ForEach(Array(analysis.sentiment.perSpeaker.keys.sorted()), id: \.self) { speaker in
                            HStack {
                                if differentiateWithoutColor {
                                    Image(systemName: SpeakerGlyph.symbol(for: speaker))
                                        .font(.system(.caption2, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                SpeakerChip(speaker: speaker)
                                Spacer()
                                Text(String(format: "%.2f", analysis.sentiment.perSpeaker[speaker] ?? 0))
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(speaker) sentiment \(String(format: "%.2f", analysis.sentiment.perSpeaker[speaker] ?? 0))")
                        }
                    }
                }

                if !analysis.entities.isEmpty {
                    InsightCard(
                        tint: .indigo,
                        icon: "person.2",
                        title: "People, Organizations & Places"
                    ) {
                        ForEach(ExtractedEntity.EntityType.allCases) { type in
                            let filtered = analysis.entities.filter { $0.type == type }
                            if !filtered.isEmpty {
                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                                    Text(type.rawValue.uppercased())
                                        .font(.system(.caption2, weight: .semibold))
                                        .tracking(0.5)
                                        .foregroundStyle(.tertiary)
                                    FlowLayoutView(items: filtered) { entity in
                                        // The glyph is the non-color cue for the
                                        // entity kind (person / org / place /
                                        // date); the capsule tint is decorative.
                                        Label(entity.text, systemImage: type.systemImage)
                                            .font(.caption)
                                            .padding(.horizontal, DesignTokens.Spacing.sm)
                                            .padding(.vertical, DesignTokens.Spacing.xs)
                                            .background(
                                                Capsule().fill(Color.secondary.opacity(0.12))
                                            )
                                            .accessibilityElement(children: .ignore)
                                            .accessibilityLabel("\(entity.text), \(type.rawValue)")
                                    }
                                }
                                .padding(.vertical, DesignTokens.Spacing.xs)
                            }
                        }
                    }
                }

                if !analysis.topics.topics.isEmpty {
                    InsightCard(tint: .purple, icon: "tag", title: "Key Topics") {
                        FlowLayoutView(items: analysis.topics.topics) { topic in
                            TagChip(text: topic, tint: .purple)
                        }
                    }
                }

                if !analysis.keyPhrases.isEmpty {
                    InsightCard(tint: .pink, icon: "quote.bubble", title: "Key Phrases") {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            ForEach(analysis.keyPhrases, id: \.self) { phrase in
                                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 4))
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 7)
                                    Text(phrase)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .modifier(RevealModifier(token: viewModel.analysisRevealToken, reduceMotion: reduceMotion))
        } else {
            EmptyStateView(
                systemImage: "chart.bar.xaxis",
                title: "No analysis yet",
                message: "Run analysis to extract entities, detect language, and score sentiment across speakers.",
                actionTitle: viewModel.segments.isEmpty ? nil : "Analyze Transcript",
                action: viewModel.segments.isEmpty ? nil : { viewModel.runAnalysis() }
            )
            .frame(minHeight: 280)
        }
    }

    // MARK: - Helpers

    private func sentimentTint(_ score: Double) -> Color {
        if score > 0.1 { return .green }
        if score < -0.1 { return .red }
        return .secondary
    }
}

// MARK: - ActionItemRow

private struct ActionItemRow: View {
    let item: ActionItem
    let isCompleted: Bool
    var isConverted: Bool = false
    let onToggle: () -> Void
    var onConvert: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Button(action: onToggle) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isCompleted ? Color.green : Color.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel(isCompleted ? "Mark as not done" : "Mark as done")
            .accessibilityAddTraits(isCompleted ? .isSelected : [])

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(item.description)
                    .font(.body)
                    .strikethrough(isCompleted, color: .secondary)
                    .foregroundStyle(isCompleted ? .secondary : .primary)
                    .textSelection(.enabled)

                HStack(spacing: DesignTokens.Spacing.md) {
                    if let assignee = item.assignee, !assignee.isEmpty {
                        Label(assignee, systemImage: "person.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let deadline = item.deadline, !deadline.isEmpty {
                        Label(deadline, systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let priority = item.priority {
                        PriorityBadge(priority: priority)
                    }
                    if let onConvert {
                        Button(action: onConvert) {
                            Label(
                                isConverted ? "Open task" : "Convert to task",
                                systemImage: isConverted ? "checkmark.square" : "plus.square.on.square"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(isConverted
                              ? "Open the linked task in the editor"
                              : "Create a task from this action item")
                        .accessibilityLabel(isConverted ? "Open linked task" : "Convert to task")
                    }
                }
            }
        }
        .cardStyle(padding: DesignTokens.Spacing.md, radius: DesignTokens.Radius.md)
        .animation(reduceMotion ? nil : .easeOut(duration: DesignTokens.Motion.fast), value: isCompleted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    /// A spoken summary of the action item: status, description, then owner /
    /// deadline / priority when present. The toggle + convert buttons remain
    /// individually focusable inside this container.
    private var accessibilityDescription: String {
        var parts: [String] = [isCompleted ? "Done" : "To do", item.description]
        if let assignee = item.assignee, !assignee.isEmpty { parts.append("assigned to \(assignee)") }
        if let deadline = item.deadline, !deadline.isEmpty { parts.append("due \(deadline)") }
        if let priority = item.priority { parts.append("\(priority.rawValue) priority") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - InsightCard

private struct InsightCard<Content: View>: View {
    let tint: Color
    let icon: String
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.14))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(DesignTokens.Typography.section)
                Spacer()
            }
            content()
        }
        .cardStyle(elevation: DesignTokens.Shadow.soft)
    }
}

// MARK: - FlowLayoutView

/// A wrapping horizontal layout built on SwiftUI's `Layout` protocol.
/// Replaces the older `GeometryReader` + `DispatchQueue.main.async` approach,
/// which AppKit flags with `_NSDetectedLayoutRecursion` because it mutates
/// state while a layout pass is already in flight.
struct FlowLayoutView<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    var body: some View {
        WrappingHStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

/// Horizontal layout that wraps its children onto new lines when they exceed
/// the proposed width. Pure `Layout` conformance — no GeometryReader, no
/// mutable state, no recursion warnings.
private struct WrappingHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + size.width + spacing > maxWidth {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                if rowWidth > 0 { rowWidth += spacing }
                rowWidth += size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight

        let finalWidth = maxWidth == .infinity ? widestRow : maxWidth
        return CGSize(width: finalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - MoveSegmentsSheet

/// Sheet that lets the user move the currently-selected segments into another
/// existing transcript session. Useful when a single recording accidentally
/// captured multiple back-to-back calls.
struct MoveSegmentsSheet: View {
    @ObservedObject var viewModel: TranscriptDetailViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move Segments")
                        .font(.system(.title3, weight: .semibold))
                    Text("\(viewModel.selectedSegmentIds.count) segment\(viewModel.selectedSegmentIds.count == 1 ? "" : "s") will be appended to the chosen transcript.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(DesignTokens.Spacing.lg)

            Divider()

            if viewModel.moveTargetCandidates.isEmpty {
                EmptyStateView(
                    systemImage: "tray",
                    title: "No other transcripts",
                    message: "Create another recording first to have somewhere to move these segments to."
                )
                .frame(minHeight: 280)
                .padding(DesignTokens.Spacing.lg)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        ForEach(viewModel.moveTargetCandidates) { candidate in
                            Button {
                                viewModel.moveSelectedSegments(to: candidate)
                                onClose()
                            } label: {
                                MoveTargetRow(session: candidate)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(DesignTokens.Spacing.lg)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

private struct MoveTargetRow: View {
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.secondary.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? "Untitled Session" : session.title)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let duration = session.durationSeconds {
                        Text("·").foregroundStyle(.tertiary)
                        Text(formatDuration(duration))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                .fill(Color.secondary.opacity(0.08))
        )
        .contentShape(Rectangle())
    }

    private func formatDuration(_ total: Int) -> String {
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %dm", h, m) }
        if m > 0 { return String(format: "%dm %ds", m, s) }
        return String(format: "%ds", s)
    }
}
