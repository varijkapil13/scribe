// Scribe/UI/Notes/UniversalSearchView.swift
import SwiftUI

/// The ⌘K command palette: type to search notes/tasks/transcripts, or run a
/// verb (record, create, navigate, open settings). Fully keyboard-driven —
/// auto-focuses on open, arrow keys move a highlight, Return runs the
/// highlighted row, Esc dismisses — and announced to VoiceOver. Glass card
/// collapses to a solid fill under Reduce Transparency / Increase Contrast.
struct UniversalSearchView: View {
    @StateObject private var vm = UniversalSearchViewModel()
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appDelegate: AppDelegate
    @Binding var isPresented: Bool
    var onNavigate: (MainSelection) -> Void

    @FocusState private var fieldFocused: Bool
    @State private var selectedIndex: Int = 0

    private struct Row: Identifiable {
        let id: Int            // flat index, drives the highlight + scroll
        let item: CommandItem
        let sectionTitle: String?  // non-nil on the first row of a section
    }

    // MARK: - Derived model

    private var actionItems: [CommandItem] {
        CommandRegistry.actions(query: vm.query, appState: appState,
                                appDelegate: appDelegate, navigate: onNavigate)
    }

    private var sections: [(title: String, items: [CommandItem])] {
        var out: [(String, [CommandItem])] = []
        if !actionItems.isEmpty { out.append(("Actions", actionItems)) }
        for sec in vm.sections {
            let items = sec.results.map { r in
                CommandItem(id: r.id, title: r.title, subtitle: r.snippet,
                            systemImage: r.icon, kind: .navigate(r.destination))
            }
            if !items.isEmpty { out.append((sec.title, items)) }
        }
        return out
    }

    private var rows: [Row] {
        var out: [Row] = []
        var idx = 0
        for (title, items) in sections {
            for (i, item) in items.enumerated() {
                out.append(Row(id: idx, item: item, sectionTitle: i == 0 ? title : nil))
                idx += 1
            }
        }
        return out
    }

    private var flat: [CommandItem] { rows.map(\.item) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search or run a command…", text: $vm.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { runSelected() }
                    .accessibilityLabel("Command bar")
                    .accessibilityHint("Type to search notes, tasks and transcripts, or run a command")
                if !vm.query.isEmpty {
                    Button { vm.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(16)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(rows) { row in
                            if let title = row.sectionTitle {
                                sectionHeader(title)
                            }
                            commandRow(row)
                                .id(row.id)
                        }
                    }
                }
                .frame(maxHeight: 420)
                .onChange(of: selectedIndex) { _, idx in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(idx, anchor: .center) }
                }
            }
        }
        .frame(width: 580)
        .scribeGlass(.hud, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
        .onAppear { fieldFocused = true }
        .onChange(of: vm.query) { _, _ in
            vm.scheduleSearch()
            selectedIndex = 0
        }
        .onChange(of: vm.sections.count) { _, _ in
            selectedIndex = min(selectedIndex, max(flat.count - 1, 0))
            AccessibilityNotification.Announcement("\(flat.count) results").post()
        }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onExitCommand { isPresented = false }
    }

    // MARK: - Rows

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityAddTraits(.isHeader)
    }

    private func commandRow(_ row: Row) -> some View {
        let isSelected = row.id == selectedIndex
        return Button {
            run(row.item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: row.item.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.item.title).font(.body)
                    if !row.item.subtitle.isEmpty {
                        Text(row.item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if let keys = row.item.shortcut {
                    KeyCapGroup(keys: keys).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.item.title)
        .accessibilityHint(row.item.subtitle.isEmpty ? actionHint(row.item) : row.item.subtitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .onHover { if $0 { selectedIndex = row.id } }
    }

    private func actionHint(_ item: CommandItem) -> String {
        switch item.kind {
        case .navigate: return "Opens this view"
        case .action: return "Runs this command"
        }
    }

    // MARK: - Run / navigate

    private func moveSelection(_ delta: Int) {
        guard !flat.isEmpty else { return }
        selectedIndex = max(0, min(selectedIndex + delta, flat.count - 1))
    }

    private func runSelected() {
        guard flat.indices.contains(selectedIndex) else { return }
        run(flat[selectedIndex])
    }

    private func run(_ item: CommandItem) {
        isPresented = false
        switch item.kind {
        case .navigate(let dest): onNavigate(dest)
        case .action(let perform): perform()
        }
    }
}
