// Scribe/UI/Ask/AskView.swift
import SwiftUI

/// "Ask Scribe" — a chat surface that answers questions across meetings,
/// summaries and notes, citing sources as clickable `[[Note Title]]` links.
struct AskView: View {

    let onNavigate: (MainSelection) -> Void

    @StateObject private var viewModel = AskViewModel()
    @FocusState private var inputFocused: Bool
    @Environment(\.scribeAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(DesignTokens.Palette.hairline)
                .frame(height: 1)
            if !viewModel.availability.isAvailable {
                unavailableBanner
            }
            conversation
            inputBar
        }
        .background(DesignTokens.Palette.ground)
        .onAppear {
            viewModel.onAppear()
            inputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeAskCitationTapped)) { note in
            guard let url = note.object as? URL,
                  let title = AskCitationLink.title(from: url) else { return }
            let messageId = AskCitationLink.messageId(from: url)
            let message = viewModel.messages.first(where: { $0.id == messageId })
                ?? AskMessage(role: .assistant, text: "")
            if let dest = viewModel.destination(forCitation: title, in: message) {
                onNavigate(dest)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            QuietListHeader(title: "Ask Scribe") {
                HStack(spacing: DesignTokens.Spacing.md) {
                    scopeMenu
                    if !viewModel.messages.isEmpty {
                        Button {
                            viewModel.clear()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear the conversation")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
            Text("Questions across your meetings, summaries and notes. Answered on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
        }
        .padding(.horizontal, DesignTokens.QuietList.gutter + DesignTokens.Spacing.xs)
        .padding(.top, DesignTokens.Spacing.xl)
        .padding(.bottom, DesignTokens.Spacing.md)
    }

    private var scopeMenu: some View {
        Menu {
            Button("All meetings") { viewModel.scope = .all }
            Button("Last 7 days") { viewModel.scope = .lastDays(7) }
            Button("Last 30 days") { viewModel.scope = .lastDays(30) }
            Menu("Notebook") {
                if viewModel.notebooks.isEmpty {
                    Text("No notebooks")
                } else {
                    ForEach(viewModel.notebooks) { notebook in
                        Button(notebook.name) {
                            viewModel.scope = .notebook(id: notebook.id, name: notebook.name)
                        }
                    }
                }
            }
            Menu("Person") {
                if viewModel.people.isEmpty {
                    Text("No people found yet")
                } else {
                    ForEach(Array(viewModel.people.prefix(40))) { person in
                        Button(person.name) {
                            viewModel.scope = .person(key: person.id, name: person.name)
                        }
                    }
                }
            }
        } label: {
            Label(viewModel.scope.label, systemImage: "scope")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Limit which meetings the answer draws from")
        .accessibilityLabel("Scope: \(viewModel.scope.label)")
    }

    private var unavailableBanner: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
            Text(unavailableText)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.QuietList.gutter + DesignTokens.Spacing.xs)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Palette.quietFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.Palette.hairline).frame(height: 1)
        }
    }

    private var unavailableText: String {
        var reason = "Apple Intelligence isn't available."
        if case .unavailable(let detail) = viewModel.availability { reason = detail }
        return "\(reason) Scribe will show the most relevant passages from your meetings instead of a written answer."
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.messages) { message in
                        AskMessageView(
                            message: message,
                            onOpenSnippet: { snippet in
                                if let dest = AskViewModel.destination(for: snippet) {
                                    onNavigate(dest)
                                }
                            }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.vertical, DesignTokens.Spacing.lg)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: viewModel.messages) { _, newValue in
                if let last = newValue.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Try asking")
                .quietListSectionHeader()
            ForEach(Self.examples, id: \.self) { example in
                Button {
                    viewModel.draft = example
                    inputFocused = true
                } label: {
                    Text(example)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            }
        }
        .padding(.top, DesignTokens.Spacing.xl)
    }

    private static let examples: [String] = [
        "What did we decide about the launch date?",
        "What are the open questions on the budget?",
        "What has been said about hiring recently?"
    ]

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            TextField("Ask about your meetings…", text: $viewModel.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($inputFocused)
                .onSubmit { viewModel.send() }
                .disabled(viewModel.isAnswering)
            if viewModel.isAnswering {
                ProgressView().controlSize(.small)
            }
            Button {
                viewModel.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canSend ? accent : DesignTokens.Palette.textTertiary)
            .disabled(!viewModel.canSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Send (⌘↩)")
            .accessibilityLabel("Send question")
        }
        .padding(.leading, DesignTokens.Spacing.lg)
        .padding(.trailing, DesignTokens.Spacing.xs + 2)
        .padding(.vertical, DesignTokens.Spacing.xs + 2)
        .quietListRaised(radius: DesignTokens.Radius.pill)
        .frame(maxWidth: 820)
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.top, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.lg)
    }
}

// MARK: - Message

private struct AskMessageView: View {
    let message: AskMessage
    let onOpenSnippet: (RetrievedSnippet) -> Void

    @State private var showSources = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: DesignTokens.Spacing.xxxl)
                VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xxs) {
                    Text(message.text)
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .padding(.vertical, DesignTokens.Spacing.sm)
                        .background(DesignTokens.Palette.quietFill,
                                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
                    if let scope = message.scopeLabel {
                        Text(scope)
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.Palette.textTertiary)
                    }
                }
            }
        case .assistant:
            assistantBody
        }
    }

    @ViewBuilder
    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if message.isPending {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Searching your meetings…")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }
            } else {
                Text(AskCitationLink.attributed(message.text, messageId: message.id))
                    .font(DesignTokens.Typography.reading(size: 15, relativeTo: .body))
                    .lineSpacing(4)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        // Captures nothing: hand the click to AskView, which
                        // knows the conversation and the navigator.
                        guard AskCitationLink.title(from: url) != nil else { return .systemAction }
                        NotificationCenter.default.post(name: .scribeAskCitationTapped, object: url)
                        return .handled
                    })

                if let notice = message.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                }

                if !message.snippets.isEmpty {
                    DisclosureGroup(isExpanded: $showSources) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(message.snippets) { snippet in
                                AskSnippetRow(snippet: snippet) { onOpenSnippet(snippet) }
                            }
                        }
                        .padding(.top, DesignTokens.Spacing.xs)
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Text("Sources")
                            Text("\(message.snippets.count)").monospacedDigit()
                        }
                        .quietListSectionHeader()
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quietListRaised()
        .onAppear {
            // Without a written answer, the sources ARE the answer.
            if !message.usedModel && !message.snippets.isEmpty { showSources = true }
        }
    }
}

private struct AskSnippetRow: View {
    let snippet: RetrievedSnippet
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text(snippet.citationTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DesignTokens.Palette.textSecondary)
                            .lineLimit(1)
                        Text(snippet.date, style: .date)
                            .font(DesignTokens.QuietList.rowMetaFont)
                            .foregroundStyle(DesignTokens.Palette.textTertiary)
                        if let speaker = snippet.speaker, !speaker.isEmpty {
                            Text(speaker)
                                .font(.system(size: 12))
                                .foregroundStyle(DesignTokens.Palette.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(snippet.text)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .quietListRowBackground(selected: false, hovered: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(snippet.kind == .note ? "Open note" : "Open meeting")
    }

    private var icon: String {
        switch snippet.kind {
        case .transcript: return "waveform"
        case .summary:    return "text.alignleft"
        case .note:       return "doc.text"
        }
    }
}
