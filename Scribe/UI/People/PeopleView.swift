// Scribe/UI/People/PeopleView.swift
import SwiftUI

/// People seen across meetings: a list with meeting / open-task counts and a
/// detail pane with their meetings, open tasks, and a person note.
struct PeopleView: View {

    let onNavigate: (MainSelection) -> Void

    @StateObject private var viewModel = PeopleViewModel()

    var body: some View {
        HStack(spacing: 0) {
            peopleList
                .frame(width: 280)
            Rectangle()
                .fill(DesignTokens.Palette.hairline)
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignTokens.Palette.ground)
        .task { await viewModel.load() }
        .alert("People", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - List

    private var peopleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuietListHeader(title: "People", count: "\(viewModel.filteredPeople.count)") {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .help("Reload people")
                .accessibilityLabel("Reload people")
                .disabled(viewModel.isLoading)
            }
            .padding(.horizontal, DesignTokens.QuietList.gutter)
            .padding(.top, DesignTokens.Spacing.xl)

            TextField("Filter", text: $viewModel.filterText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, DesignTokens.QuietList.gutter)
                .padding(.top, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.sm)

            if viewModel.isLoading && viewModel.people.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(viewModel.filteredPeople) { person in
                                PersonRow(person: person, isSelected: viewModel.selectedId == person.id) {
                                    viewModel.select(person.id)
                                }
                                .id(person.id)
                            }
                        }
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .padding(.bottom, DesignTokens.Spacing.md)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.upArrow) { moveSelection(by: -1, proxy: proxy) }
                    .onKeyPress(.downArrow) { moveSelection(by: 1, proxy: proxy) }
                }
            }
        }
    }

    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let people = viewModel.filteredPeople
        guard !people.isEmpty else { return .ignored }
        let current = people.firstIndex { $0.id == viewModel.selectedId }
        let next = current.map { min(max($0 + offset, 0), people.count - 1) } ?? 0
        let id = people[next].id
        viewModel.select(id)
        proxy.scrollTo(id)
        return .handled
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let person = viewModel.selectedPerson {
            PersonDetailView(
                person: person,
                noteId: viewModel.selectedNoteId,
                onNavigate: onNavigate,
                onCreateNote: {
                    if let id = viewModel.createOrRefreshNote(for: person) {
                        onNavigate(.note(id))
                    }
                },
                onRefreshNote: {
                    _ = viewModel.createOrRefreshNote(for: person)
                }
            )
            .id(person.id)
        } else if !viewModel.isLoading && viewModel.people.isEmpty {
            EmptyStateView(
                systemImage: "person.2",
                title: "No people yet",
                message: "People appear here once names are picked up from your recordings — named speakers, people mentioned in transcripts, and action-item assignees."
            )
        } else {
            EmptyStateView(
                systemImage: "person.crop.circle",
                title: "Select a person",
                message: "See the meetings they were in and the open tasks that mention them."
            )
        }
    }
}

// MARK: - Row

private struct PersonRow: View {
    let person: Person
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(person.name)
                    .font(DesignTokens.QuietList.rowTitleFont.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.Spacing.sm)
                Text(compactSummary)
                    .font(DesignTokens.QuietList.rowMetaFont)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(minHeight: DesignTokens.QuietList.rowHeight)
            .quietListRowBackground(selected: isSelected, hovered: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(person.name), \(summary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var compactSummary: String {
        person.openTasks.isEmpty
            ? "\(person.meetingCount)"
            : "\(person.meetingCount) · \(person.openTasks.count) open"
    }

    private var summary: String {
        let meetings = person.meetingCount == 1 ? "1 meeting" : "\(person.meetingCount) meetings"
        switch person.openTasks.count {
        case 0:  return meetings
        case 1:  return "\(meetings) · 1 open task"
        default: return "\(meetings) · \(person.openTasks.count) open tasks"
        }
    }
}

// MARK: - Detail

private struct PersonDetailView: View {
    let person: Person
    let noteId: String?
    let onNavigate: (MainSelection) -> Void
    let onCreateNote: () -> Void
    let onRefreshNote: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                header
                meetingsSection
                tasksSection
            }
            .padding(.horizontal, DesignTokens.Spacing.xxl)
            .padding(.vertical, DesignTokens.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The person's other names as a locale-formatted list ("A, B and C").
    private var otherNames: String {
        person.aliases.filter { $0 != person.id }.formatted(.list(type: .and))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(person.name)
                .font(DesignTokens.Typography.display(size: 24))
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .textSelection(.enabled)
            if person.aliases.count > 1 {
                Text("Also seen as \(otherNames)")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                if let noteId {
                    Button {
                        onNavigate(.note(noteId))
                    } label: {
                        Label("Open person note", systemImage: "doc.text")
                    }
                    Button {
                        onRefreshNote()
                    } label: {
                        Label("Refresh note", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Regenerate the meetings and tasks block. Your own text is kept.")
                } else {
                    Button {
                        onCreateNote()
                    } label: {
                        Label("Create person note", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Write a note for \(person.name) in the People notebook, linking their meetings and open tasks.")
                }
            }
            .controlSize(.small)
            .padding(.top, DesignTokens.Spacing.xs)
        }
    }

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Meetings", count: person.meetingCount)
            ForEach(person.meetings) { meeting in
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button {
                        if let noteId = meeting.noteId {
                            onNavigate(.note(noteId))
                        } else {
                            onNavigate(.session(meeting.sessionId))
                        }
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 12))
                                .foregroundStyle(DesignTokens.Palette.textTertiary)
                                .frame(width: 16)
                            Text(meeting.linkTitle)
                                .font(DesignTokens.QuietList.rowTitleFont)
                                .foregroundStyle(DesignTokens.Palette.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: DesignTokens.Spacing.sm)
                            Text(meeting.date, style: .date)
                                .font(DesignTokens.QuietList.rowMetaFont)
                                .foregroundStyle(DesignTokens.Palette.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        onNavigate(.session(meeting.sessionId))
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .help("Open transcript")
                    .accessibilityLabel("Open transcript for \(meeting.linkTitle)")
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .frame(minHeight: DesignTokens.QuietList.rowHeight)
                .overlay(alignment: .bottom) { hairline }
            }
        }
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Open tasks", count: person.openTasks.count)
            if person.openTasks.isEmpty {
                Text("No open tasks mention \(person.name).")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.top, DesignTokens.Spacing.xs)
            } else {
                ForEach(person.openTasks) { task in
                    Button {
                        onNavigate(.task(task.id))
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Image(systemName: "circle")
                                .font(.system(size: 14))
                                .foregroundStyle(DesignTokens.Palette.textTertiary)
                                .frame(width: 16)
                            Text(task.title)
                                .font(DesignTokens.QuietList.rowTitleFont)
                                .foregroundStyle(DesignTokens.Palette.textPrimary)
                                .lineLimit(2)
                            Spacer(minLength: DesignTokens.Spacing.sm)
                            if let due = task.dueAt {
                                Text(due, style: .date)
                                    .font(DesignTokens.QuietList.rowMetaFont)
                                    .foregroundStyle(due < Date() ? DesignTokens.Palette.overdue : DesignTokens.Palette.textTertiary)
                            }
                        }
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .frame(minHeight: DesignTokens.QuietList.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { hairline }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(title)
            Text("\(count)").monospacedDigit()
        }
        .quietListSectionHeader()
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var hairline: some View {
        Rectangle()
            .fill(DesignTokens.Palette.hairline)
            .frame(height: 1)
            .padding(.leading, DesignTokens.Spacing.sm + 24)
    }
}
