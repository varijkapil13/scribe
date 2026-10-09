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
                .frame(width: 260)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignTokens.Palette.surface)
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
        VStack(spacing: 0) {
            HStack {
                Text("People")
                    .font(DesignTokens.Typography.section)
                Spacer()
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reload people")
                .disabled(viewModel.isLoading)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.top, DesignTokens.Spacing.md)

            TextField("Filter", text: $viewModel.filterText)
                .textFieldStyle(.roundedBorder)
                .padding(DesignTokens.Spacing.md)

            if viewModel.isLoading && viewModel.people.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { viewModel.selectedId },
                    set: { viewModel.select($0) }
                )) {
                    ForEach(viewModel.filteredPeople) { person in
                        PersonRow(person: person)
                            .tag(person.id as String?)
                    }
                }
                .listStyle(.sidebar)
            }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(person.name)
                .font(DesignTokens.Typography.body)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .accessibilityElement(children: .combine)
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
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(person.name)
                .font(DesignTokens.Typography.title2)
                .textSelection(.enabled)
            if person.aliases.count > 1 {
                Text("Also seen as: " + person.aliases.filter { $0 != person.id }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                if let noteId {
                    Button {
                        onNavigate(.note(noteId))
                    } label: {
                        Label("Open person note", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
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
            .padding(.top, DesignTokens.Spacing.xs)
        }
    }

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Meetings (\(person.meetingCount))")
                .eyebrowStyle()
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
                                .foregroundStyle(.secondary)
                            Text(meeting.linkTitle)
                                .lineLimit(1)
                            Spacer(minLength: DesignTokens.Spacing.sm)
                            Text(meeting.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        onNavigate(.session(meeting.sessionId))
                    } label: {
                        Image(systemName: "waveform")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open transcript")
                    .accessibilityLabel("Open transcript for \(meeting.linkTitle)")
                }
                .padding(.vertical, DesignTokens.Spacing.xxs)
            }
        }
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Open tasks (\(person.openTasks.count))")
                .eyebrowStyle()
            if person.openTasks.isEmpty {
                Text("No open tasks mention \(person.name).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(person.openTasks) { task in
                    Button {
                        onNavigate(.task(task.id))
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                            Text(task.title)
                                .lineLimit(2)
                            Spacer(minLength: DesignTokens.Spacing.sm)
                            if let due = task.dueAt {
                                Text(due, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, DesignTokens.Spacing.xxs)
                }
            }
        }
    }
}
