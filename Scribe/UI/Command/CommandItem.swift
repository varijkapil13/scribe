import SwiftUI

/// A single row in the ⌘K command palette: either a navigation jump or an
/// action verb. Unifies search hits and commands under one keyboard-driven
/// model so the palette runs verbs, not just finds nouns (Arc's command bar).
enum CommandKind {
    case navigate(MainSelection)
    case action(@MainActor () -> Void)
}

struct CommandItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    /// Display-only keycaps (e.g. `["⇧","⌘","R"]`). The *real* shortcut lives
    /// on the corresponding menu item so VoiceOver announces it once.
    let shortcut: [String]?
    let kind: CommandKind

    init(id: String,
         title: String,
         subtitle: String = "",
         systemImage: String,
         shortcut: [String]? = nil,
         kind: CommandKind) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.kind = kind
    }
}
