import SwiftUI

// Planning UI pieces for `TaskListView` (project headings + when-buckets),
// kept out of that already-large file.

/// Which heading text prompt is showing in a project task list.
enum HeadingPrompt: Equatable, Identifiable {
    case add
    case rename(ProjectHeading)

    var id: String {
        switch self {
        case .add:                 return "add"
        case .rename(let heading): return "rename.\(heading.id)"
        }
    }

    var title: String {
        switch self {
        case .add:    return "New Heading"
        case .rename: return "Rename Heading"
        }
    }

    var initialText: String {
        if case .rename(let heading) = self { return heading.title }
        return ""
    }
}

/// Text-field alert for adding / renaming a project heading.
struct HeadingPromptModifier: ViewModifier {
    @Binding var prompt: HeadingPrompt?
    let onCommit: (HeadingPrompt, String) -> Void

    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert(
                prompt?.title ?? "Heading",
                isPresented: Binding(
                    get: { prompt != nil },
                    set: { if !$0 { prompt = nil } }
                )
            ) {
                TextField("Heading name", text: $draft)
                Button("Save") {
                    if let current = prompt { onCommit(current, draft) }
                    prompt = nil
                }
                Button("Cancel", role: .cancel) { prompt = nil }
            }
            .onChange(of: prompt) { _, newValue in
                draft = newValue?.initialText ?? ""
            }
    }
}

/// Context-menu items for a heading section header.
struct HeadingSectionMenu: View {
    let heading: ProjectHeading
    let isFirst: Bool
    let isLast: Bool
    let onRename: () -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onRename) { Label("Rename Heading…", systemImage: "pencil") }
        Button { onMove(-1) } label: { Label("Move Up", systemImage: "arrow.up") }
            .disabled(isFirst)
        Button { onMove(1) } label: { Label("Move Down", systemImage: "arrow.down") }
            .disabled(isLast)
        Divider()
        Button(role: .destructive, action: onDelete) {
            Label("Delete Heading", systemImage: "trash")
        }
    }
}

/// Row context-menu submenu: Things-style "When" plan for a task.
struct TaskWhenMenu: View {
    let task: TodoTask
    let onSelect: (TaskScheduleBucket) -> Void

    var body: some View {
        Menu {
            ForEach(TaskScheduleBucket.allCases, id: \.self) { bucket in
                Button { onSelect(bucket) } label: {
                    Label(bucket.title,
                          systemImage: task.scheduleBucket == bucket ? "checkmark" : bucket.systemImage)
                }
            }
        } label: {
            Label("When", systemImage: "moon.stars")
        }
    }
}

/// Row context-menu submenu: file a task under one of the project's headings.
struct TaskHeadingMenu: View {
    let task: TodoTask
    let headings: [ProjectHeading]
    let onSelect: (String?) -> Void

    var body: some View {
        Menu {
            Button { onSelect(nil) } label: {
                Label("No Heading", systemImage: task.headingId == nil ? "checkmark" : "minus")
            }
            Divider()
            ForEach(headings) { heading in
                Button { onSelect(heading.id) } label: {
                    Label(heading.title,
                          systemImage: task.headingId == heading.id ? "checkmark" : "text.line.first.and.arrowtriangle.forward")
                }
            }
        } label: {
            Label("Heading", systemImage: "list.bullet.indent")
        }
    }
}

/// Compact "~30m" / "~1h 30m" estimate text.
enum TaskDurationFormat {
    static func short(_ minutes: Int) -> String {
        guard minutes > 0 else { return "0m" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }
}
