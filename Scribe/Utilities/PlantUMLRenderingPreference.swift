// Scribe/Utilities/PlantUMLRenderingPreference.swift
//
// Pure Foundation (no zlib), so it is also compiled into the iOS target for
// the shared CodeMirror editor host (WebEditorCore.swift).
import Foundation

/// Opt-in preference for rendering ```plantuml``` fences through the public
/// plantuml.com server. Rendering there sends the diagram source over the
/// internet, so it is OFF by default; the note editor shows a placeholder
/// instead of fetching until the user enables it in Settings.
///
/// The value reaches the web editor two ways (see WebMarkdownEditor and
/// editor-web/src/diagrams.js): a document-start user script defining
/// `window.scribeConfig` (read once when the bundle loads) and
/// `window.scribeSetPlantUMLRemote(bool)` for live changes.
enum PlantUMLRenderingPreference {
    /// UserDefaults / @AppStorage key for the toggle.
    static let remoteEnabledKey = "editor.plantUMLRemoteRendering"

    /// Privacy default: never contact plantuml.com unless the user opts in.
    static let defaultValue = false

    /// Reads the persisted toggle, falling back to `defaultValue` when unset.
    static func isRemoteEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: remoteEnabledKey) != nil else { return defaultValue }
        return defaults.bool(forKey: remoteEnabledKey)
    }

    /// JavaScript injected at document start so the editor bundle knows the
    /// setting before it renders any diagram.
    static func configScript(remoteEnabled: Bool) -> String {
        "window.scribeConfig = Object.assign(window.scribeConfig || {}, { plantUMLRemote: \(remoteEnabled ? "true" : "false") });"
    }

    /// JavaScript that pushes a live change of the toggle to a mounted editor.
    static func setRemoteScript(remoteEnabled: Bool) -> String {
        "window.scribeSetPlantUMLRemote && window.scribeSetPlantUMLRemote(\(remoteEnabled ? "true" : "false"));"
    }
}
