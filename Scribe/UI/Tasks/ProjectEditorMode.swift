import Foundation

/// Identifies the project-editor sheet's mode. Kept in its own file (in the
/// SwiftPM test target) because `MainWindowView` — which presents it — is
/// excluded from that target, while `ProjectEditorView` stays in it.
enum ProjectEditorMode: Identifiable, Hashable {
    case create
    case edit(Project)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let project): return "edit-\(project.id)"
        }
    }
}
