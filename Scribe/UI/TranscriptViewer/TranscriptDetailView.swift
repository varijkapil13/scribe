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
    /// Playback of the session's retained audio (inert when it has none).
    @StateObject private var audioPlayer = SessionAudioPlayer()
    /// Bookmarked moments (meeting copilot): Highlights + timeline markers.
    @StateObject private var highlights = SessionHighlightsModel(store: .shared)
    @State private var showFollowUp = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .padding(.bottom, DesignTokens.Spacing.md)

            tabPicker
                .padding(.horizontal, DesignTokens.Spacing.xl - DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.md)

            Rectangle()
                .fill(DesignTokens.Palette.hairline)
                .frame(height: 1)
                .padding(.bottom, DesignTokens.Spacing.md)

            if audioPlayer.hasAudio {
                SessionAudioPlayerBar(player: audioPlayer)
                    .environment(\.playbackBookmarkOffsets, highlights.bookmarks.map(\.offsetMs))
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.bottom, DesignTokens.Spacing.md)
            } else if MeetingSyncScheduler.shared.canDownloadAudio(sessionId: session.id) {
                // Meeting synced from another device: its audio is in iCloud.
                MeetingAudioDownloadButton(sessionId: session.id) { _ in
                    viewModel.reloadSession()
                    audioPlayer.load(session: viewModel.session)
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.bottom, DesignTokens.Spacing.md)
            }

            ScrollView {
                Group {
                    switch selectedTab {
                    case .transcript:  transcriptSection
                    case .summary:     summaryTabContent
                    case .actionItems: actionItemsSection
                    case .insights:    insightsSection
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.vertical, DesignTokens.Spacing.lg)
            }
        }
        .frame(minWidth: 600, minHeight: 480)
        .background(DesignTokens.Palette.ground)
        .sheet(isPresented: $showExportSheet) {
            ExportSheetView(session: session, segments: viewModel.segments)
        }
        .sheet(isPresented: $showFollowUp) {
            FollowUpEmailSheet(
                session: viewModel.session,
                summary: viewModel.meetingSummary,
                highlights: highlights.plainLines(
                    segments: viewModel.segments,
                    speakerName: { viewModel.speakerName(for: $0) }
                ),
                onClose: { showFollowUp = false }
            )
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
            // Re-read the row: the session handed in may predate (or, from
            // search, omit) its audio folder.
            viewModel.reloadSession()
            audioPlayer.load(session: viewModel.session)
            highlights.load(sessionId: session.id)
        }
        .onDisappear { audioPlayer.stop() }
        .onChange(of: viewModel.segments, initial: true) { _, segments in
            audioPlayer.segments = segments
        }
        // Background diarization finished: segments were split/relabelled.
        .onReceive(NotificationCenter.default.publisher(for: .scribeSpeakersDidChange)) { note in
            if (note.object as? String) == viewModel.session.id {
                viewModel.loadSegments()
            }
        }
        // Meeting sync imported a newer version of this meeting.
        .onReceive(NotificationCenter.default.publisher(for: .scribeMeetingSyncDidChangeSessions)) { note in
            if let ids = note.object as? [String], ids.contains(viewModel.session.id) {
                viewModel.reloadSession()
                viewModel.loadSegments()
                viewModel.loadSummary()
            }
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
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Recordings")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(session.title.isEmpty ? "Untitled Session" : session.title)
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location: Recordings, \(session.title.isEmpty ? "Untitled Session" : session.title)")

                HStack(alignment: .firstTextBaseline) {
                    Text(session.title.isEmpty ? "Untitled Session" : session.title)
                        .font(DesignTokens.Typography.display(size: 24))
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
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
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .help("Rename session and edit tags")
                }

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(formattedDate)
                    Text("·")
                    Text(viewModel.formattedDuration)
                    if let lang = session.language?.uppercased(), !lang.isEmpty, lang != "AUTO" {
                        Text("·")
                        Text(lang)
                    }
                    if !viewModel.segments.isEmpty {
                        Text("·")
                        Text("\(viewModel.segments.count) segments")
                    }
                    if !session.tags.isEmpty {
                        Text("·")
                        Text(session.tags.map { "#\($0)" }.joined(separator: " "))
                            .lineLimit(1)
                    }
                    MeetingOriginBadge(sessionId: session.id)
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(DesignTokens.Palette.textTertiary)

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
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                Button {
                    viewModel.loadMoveTargets()
                    showMoveSheet = true
                } label: { Label("Move To…", systemImage: "arrow.right.doc.on.clipboard") }
                    .disabled(viewModel.selectedSegmentIds.isEmpty)
                AssignSpeakerMenu(viewModel: viewModel)
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

                SessionTemplateActionsMenu(session: viewModel.session)
                    .disabled(viewModel.segments.isEmpty)

                Button { showFollowUp = true } label: {
                    Label("Follow-up", systemImage: "envelope")
                }
                .disabled(viewModel.segments.isEmpty)
                .help("Draft a follow-up email to the attendees")

                Spacer()

                SpeakersButton(viewModel: viewModel)

                Button { viewModel.toggleSelectMode() } label: {
                    Label("Select", systemImage: "checklist")
                }
                .disabled(viewModel.segments.isEmpty)
                .help("Select segments to move them or assign a speaker")

                Button { showExportSheet = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export transcript to Markdown, plain text, or JSON")
            }
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .labelStyle(.titleAndIcon)
        .font(.system(size: 12))
        .foregroundStyle(DesignTokens.Palette.textSecondary)
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

    private var tabPicker: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                tabButton(for: tab)
            }
            Spacer()
        }
        // Left/Right arrows move between tabs when any tab owns keyboard focus,
        // matching the VoiceOver tab-bar idiom.
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
            Text(tab.rawValue)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? DesignTokens.Palette.textPrimary : DesignTokens.Palette.textSecondary)
                .padding(.horizontal, DesignTokens.Spacing.sm + 2)
                .frame(height: 28)
                .quietListRowBackground(selected: isSelected)
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

    /// Selects a tab, gating the animation on Reduce Motion, and
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
            LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                let playingSegmentId = audioPlayer.currentSegmentId
                ForEach(viewModel.segments) { segment in
                    SegmentView(
                        segment: segment,
                        isSelecting: viewModel.isSelecting,
                        isSelected: segment.id.map { viewModel.selectedSegmentIds.contains($0) } ?? false,
                        onToggleSelection: {
                            if let id = segment.id {
                                viewModel.toggleSegmentSelection(id)
                            }
                        },
                        isCurrent: playingSegmentId != nil && segment.id == playingSegmentId,
                        onTimestampTap: playAction(for: segment),
                        speakerName: viewModel.speakerName(for: segment)
                    )
                }
            }
        }
    }

    /// Seek-and-play action for a segment's timestamp, or nil when the
    /// session has no audio (the timestamp then stays plain text).
    private func playAction(for segment: Segment) -> (() -> Void)? {
        guard audioPlayer.hasAudio else { return nil }
        let player = audioPlayer
        let startMs = segment.startMs
        return { player.playFrom(ms: startMs) }
    }

    // MARK: - Summary

    /// Summary tab: share row, bookmarked highlights, then the summary.
    /// Kept out of `body` to spare the type checker.
    private var summaryTabContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            summaryShareRow
            SessionHighlightsSection(
                model: highlights,
                segments: viewModel.segments,
                speakerName: { viewModel.speakerName(for: $0) },
                onPlay: highlightPlayAction
            )
            summarySection
        }
    }

    /// Seek-and-play for a highlight, or nil without audio.
    private var highlightPlayAction: ((Int) -> Void)? {
        guard audioPlayer.hasAudio else { return nil }
        let player = audioPlayer
        return { ms in player.playFrom(ms: ms) }
    }

    /// "Share" for the stored summary (sharing picker via ShareLink).
    @ViewBuilder
    private var summaryShareRow: some View {
        if let summary = viewModel.meetingSummary {
            HStack {
                Spacer()
                ShareLink(
                    item: FollowUpEmailComposer.summaryShareText(
                        title: session.title,
                        summary: summary,
                        highlights: highlights.plainLines(
                            segments: viewModel.segments,
                            speakerName: { viewModel.speakerName(for: $0) }
                        )
                    ),
                    subject: Text(session.title)
                ) {
                    Label("Share Summary", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
            }
        }
    }

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
                        .foregroundStyle(DesignTokens.Palette.overdue)
                    Text("Summary failed")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                }
                Text(error)
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .textSelection(.enabled)
                Button("Try Again") {
                    Task { await viewModel.generateSummary() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.segments.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.lg)
            .quietListRaised()
        } else if let summary = viewModel.meetingSummary {
            VStack(alignment: .leading, spacing: DesignTokens.QuietList.sectionSpacing + DesignTokens.Spacing.xs) {
                QuietSection(title: "Executive summary") {
                    Text(summary.summary)
                        .font(DesignTokens.Typography.reading)
                        .lineSpacing(5)
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Executive summary. \(summary.summary)")

                if !summary.keyDecisions.isEmpty {
                    QuietSection(title: "Key decisions") {
                        ForEach(summary.keyDecisions, id: \.self) { decision in
                            QuietBulletRow(systemImage: "checkmark", text: decision)
                        }
                    }
                }

                if !summary.keyTopics.isEmpty {
                    QuietSection(title: "Topics discussed") {
                        FlowLayoutView(items: summary.keyTopics) { topic in
                            QuietChip(text: topic)
                        }
                    }
                }

                if !summary.followUpQuestions.isEmpty {
                    QuietSection(title: "Follow-up questions") {
                        ForEach(summary.followUpQuestions, id: \.self) { question in
                            QuietBulletRow(systemImage: "questionmark", text: question)
                        }
                    }
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
            VStack(alignment: .leading, spacing: 0) {
                Text("\(summary.actionItems.count) action item\(summary.actionItems.count == 1 ? "" : "s")")
                    .quietListSectionHeader()
                    .monospacedDigit()
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.bottom, DesignTokens.Spacing.sm)
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
                        .foregroundStyle(DesignTokens.Palette.overdue)
                    Text("Analysis failed")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                }
                Text(error)
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .textSelection(.enabled)
                Button("Try Again") {
                    viewModel.runAnalysis()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.segments.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.lg)
            .quietListRaised()
        } else if let analysis = viewModel.transcriptAnalysis {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                InsightCard(icon: "globe", title: "Language") {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                        Text(analysis.language.primaryLanguageName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.Palette.textPrimary)
                        Text("\(Int(analysis.language.confidence * 100))% confidence")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(DesignTokens.Palette.textTertiary)
                    }
                }

                InsightCard(icon: "heart.text.square", title: "Sentiment") {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                        Text(analysis.sentiment.label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.Palette.textPrimary)
                        Text(String(format: "%.2f", analysis.sentiment.overallScore))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(DesignTokens.Palette.textTertiary)
                    }
                    if !analysis.sentiment.perSpeaker.isEmpty {
                        Rectangle()
                            .fill(DesignTokens.Palette.hairline)
                            .frame(height: 1)
                            .padding(.vertical, DesignTokens.Spacing.xs)
                        ForEach(Array(analysis.sentiment.perSpeaker.keys.sorted()), id: \.self) { speaker in
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                if differentiateWithoutColor {
                                    Image(systemName: SpeakerGlyph.symbol(for: speaker))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                                        .accessibilityHidden(true)
                                } else {
                                    Circle()
                                        .fill(Color.speakerTint(for: speaker).opacity(0.7))
                                        .frame(width: 6, height: 6)
                                        .accessibilityHidden(true)
                                }
                                Text(speakerLabel(speaker))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                                Spacer()
                                Text(String(format: "%.2f", analysis.sentiment.perSpeaker[speaker] ?? 0))
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                            }
                            .frame(minHeight: 24)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(speaker) sentiment \(String(format: "%.2f", analysis.sentiment.perSpeaker[speaker] ?? 0))")
                        }
                    }
                }

                if !analysis.entities.isEmpty {
                    InsightCard(icon: "person.2", title: "People, organizations & places") {
                        ForEach(ExtractedEntity.EntityType.allCases) { type in
                            let filtered = analysis.entities.filter { $0.type == type }
                            if !filtered.isEmpty {
                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                                    Text(type.rawValue.capitalized)
                                        .quietListSectionHeader()
                                    FlowLayoutView(items: filtered) { entity in
                                        QuietChip(text: entity.text, systemImage: type.systemImage)
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
                    InsightCard(icon: "tag", title: "Key topics") {
                        FlowLayoutView(items: analysis.topics.topics) { topic in
                            QuietChip(text: topic)
                        }
                    }
                }

                if !analysis.keyPhrases.isEmpty {
                    InsightCard(icon: "quote.bubble", title: "Key phrases") {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            ForEach(analysis.keyPhrases, id: \.self) { phrase in
                                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 4))
                                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                                        .padding(.top, 7)
                                    Text(phrase)
                                        .font(.system(size: 13))
                                        .foregroundStyle(DesignTokens.Palette.textPrimary)
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

    private func speakerLabel(_ speaker: String) -> String {
        switch speaker.lowercased() {
        case "you":    return "You"
        case "remote": return "Remote"
        default:       return speaker.capitalized
        }
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
    @Environment(\.scribeAccent) private var accent
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Button(action: onToggle) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isCompleted ? accent : DesignTokens.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .accessibilityLabel(isCompleted ? "Mark as not done" : "Mark as done")
            .accessibilityAddTraits(isCompleted ? .isSelected : [])

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(item.description)
                    .font(DesignTokens.QuietList.rowTitleFont)
                    .strikethrough(isCompleted, color: DesignTokens.Palette.textTertiary)
                    .foregroundStyle(isCompleted ? DesignTokens.Palette.textTertiary : DesignTokens.Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if hasMeta {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        if let assignee = item.assignee, !assignee.isEmpty {
                            Text(assignee)
                        }
                        if let deadline = item.deadline, !deadline.isEmpty {
                            Text(deadline)
                        }
                        if let priority = item.priority {
                            Text("\(priority.rawValue.capitalized) priority")
                                .foregroundStyle(priority == .high
                                                 ? DesignTokens.Palette.overdue
                                                 : DesignTokens.Palette.textTertiary)
                        }
                    }
                    .font(DesignTokens.QuietList.rowMetaFont)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            if let onConvert {
                Button(action: onConvert) {
                    Text(isConverted ? "Open task" : "Convert to task")
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
                .help(isConverted
                      ? "Open the linked task in the editor"
                      : "Create a task from this action item")
                .accessibilityLabel(isConverted ? "Open linked task" : "Convert to task")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm + 1)
        .frame(minHeight: DesignTokens.QuietList.rowHeight + 4)
        .quietListRowBackground(selected: false, hovered: hovered)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.Palette.hairline)
                .frame(height: 1)
                .padding(.leading, DesignTokens.Spacing.sm + 28)
        }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: DesignTokens.Motion.fast), value: isCompleted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var hasMeta: Bool {
        !(item.assignee ?? "").isEmpty || !(item.deadline ?? "").isEmpty || item.priority != nil
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

// MARK: - Quiet building blocks

private struct InsightCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .accessibilityHidden(true)
                Text(title)
                    .quietListSectionHeader()
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            content()
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quietListRaised()
    }
}

private struct QuietSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .quietListSectionHeader()
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuietBulletRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private struct QuietChip: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
            }
            Text(text)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 3)
        .background(Capsule().fill(DesignTokens.Palette.quietFill))
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
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text("Move Segments")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                    Text("\(viewModel.selectedSegmentIds.count) segment\(viewModel.selectedSegmentIds.count == 1 ? "" : "s") will be appended to the chosen transcript.")
                        .font(.callout)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(DesignTokens.Spacing.lg)

            Rectangle()
                .fill(DesignTokens.Palette.hairline)
                .frame(height: 1)

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
                    LazyVStack(alignment: .leading, spacing: 0) {
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
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .frame(width: 16)

            Text(session.title.isEmpty ? "Untitled Session" : session.title)
                .font(DesignTokens.QuietList.rowTitleFont)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: DesignTokens.Spacing.md)

            HStack(spacing: DesignTokens.Spacing.sm) {
                if let duration = session.durationSeconds {
                    Text(formatDuration(duration))
                }
                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(DesignTokens.QuietList.rowMetaFont)
            .foregroundStyle(DesignTokens.Palette.textTertiary)
            .lineLimit(1)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(minHeight: DesignTokens.QuietList.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quietListRowBackground(selected: false, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private func formatDuration(_ total: Int) -> String {
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %dm", h, m) }
        if m > 0 { return String(format: "%dm %ds", m, s) }
        return String(format: "%ds", s)
    }
}
