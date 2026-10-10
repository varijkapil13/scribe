import SwiftUI

/// Sidebar "Areas" section for the Tasks surface (Things-style areas that
/// group projects). Each row opens the area's task list (`.area(id)`), lists
/// its projects as an at-a-glance caption, and offers rename / delete; the
/// header's "+" creates an area. Rows reorder by drag.
struct TaskAreasSidebarSection: View {
    @ObservedObject var viewModel: ProjectsViewModel
    let isSelected: (String) -> Bool
    let onSelect: (String) -> Void
    /// Called after an area is deleted (so the host can leave its list).
    var onDeleted: ((String) -> Void)? = nil

    @State private var isExpanded = true
    @State private var prompt: TaskAreaPrompt?
    @State private var draft = ""
    @State private var pendingDelete: TaskArea?

    var body: some View {
        Section {
            if isExpanded {
                ForEach(viewModel.areas) { area in
                    SidebarRow(isSelected: isSelected(area.id), action: { onSelect(area.id) }) {
                        row(for: area)
                    }
                    .contextMenu {
                        Button {
                            draft = area.name
                            prompt = .rename(area)
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            pendingDelete = area
                        } label: {
                            Label("Delete area", systemImage: "trash")
                        }
                    }
                }
                .onMove { source, destination in
                    viewModel.reorderAreas(from: source, to: destination)
                }
            }
        } header: {
            HStack(alignment: .center) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Areas")
                            .eyebrowStyle()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeOut(duration: 0.18), value: isExpanded)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    draft = ""
                    prompt = .create
                } label: {
                    Image(systemName: "plus.circle")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New area")
            }
            .alert(
                prompt?.title ?? "Area",
                isPresented: Binding(
                    get: { prompt != nil },
                    set: { if !$0 { prompt = nil } }
                )
            ) {
                TextField("Area name", text: $draft)
                Button("Save") { commitPrompt() }
                Button("Cancel", role: .cancel) { prompt = nil }
            }
            .confirmationDialog(
                pendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete area?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Area", role: .destructive) {
                    if let area = pendingDelete {
                        viewModel.deleteArea(id: area.id)
                        onDeleted?(area.id)
                    }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("Its projects and tasks stay — they just won't be grouped under this area.")
            }
        }
    }

    @ViewBuilder
    private func row(for area: TaskArea) -> some View {
        let projectNames = viewModel.projectsInArea(area.id).map(\.name)
        VStack(alignment: .leading, spacing: 1) {
            Label(area.name, systemImage: area.symbol ?? "square.stack.3d.up")
            if !projectNames.isEmpty {
                Text(projectNames.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 22)
            }
        }
    }

    private func commitPrompt() {
        switch prompt {
        case .create:
            viewModel.createArea(name: draft)
        case .rename(let area):
            viewModel.renameArea(area, to: draft)
        case .none:
            break
        }
        prompt = nil
    }
}

/// Which area text prompt the sidebar section is showing.
enum TaskAreaPrompt: Equatable {
    case create
    case rename(TaskArea)

    var title: String {
        switch self {
        case .create: return "New Area"
        case .rename: return "Rename Area"
        }
    }
}

/// Context-menu submenu on a sidebar project row: file it under an area.
struct ProjectAreaMenu: View {
    let project: Project
    let areas: [TaskArea]
    let onAssign: (String?) -> Void

    var body: some View {
        if !areas.isEmpty {
            Menu {
                Button { onAssign(nil) } label: {
                    Label("No Area", systemImage: project.areaId == nil ? "checkmark" : "minus")
                }
                Divider()
                ForEach(areas) { area in
                    Button { onAssign(area.id) } label: {
                        Label(area.name,
                              systemImage: project.areaId == area.id ? "checkmark" : (area.symbol ?? "square.stack.3d.up"))
                    }
                }
            } label: {
                Label("Area", systemImage: "square.stack.3d.up")
            }
        }
    }
}
