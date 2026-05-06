import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Transferable payload used when dragging a task onto a project sidebar row.
/// Carries just the task id; the drop site looks up the row in `TaskStore`.
struct TaskDragPayload: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .scribeTask)
    }
}

extension UTType {
    /// Custom drag UTI for in-app task moves. Conforms to `data` so SwiftUI's
    /// `dropDestination` accepts it without requiring a public registration.
    static let scribeTask = UTType(exportedAs: "com.varij.scribe.task")
}
