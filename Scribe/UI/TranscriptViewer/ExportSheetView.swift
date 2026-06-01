import SwiftUI
import AppKit

/// Sheet view that lets the user choose an export format, preview the
/// output, and save or copy the transcript.
///
/// The format picker is a labelled radio group (rather than a bare segmented
/// control) so each option carries a glyph, a one-line description, and a
/// VoiceOver label explaining what the format is for.
struct ExportSheetView: View {

    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let session: Session
    let segments: [Segment]

    @State var selectedFormat: ExportFormat = .markdown
    @State var preview: String = ""
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export Transcript")
                    .font(.system(.title3, weight: .semibold))
                Text(session.title.isEmpty ? "Untitled Session" : session.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            formatPicker

            // Preview area — content surface, deliberately solid (never glass).
            ScrollView {
                Text(preview)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 280)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
            .readerCardBorder(contrast)
            .accessibilityLabel("Export preview")
            .accessibilityValue(preview)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(preview, forType: .string)
                    if reduceMotion {
                        copied = true
                    } else {
                        withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) { copied = true }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy to Clipboard",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the \(selectedFormat.rawValue) export to the clipboard")
                .accessibilityLabel(copied ? "Copied to clipboard" : "Copy \(selectedFormat.rawValue) to clipboard")

                Button {
                    let defaultName = session.title
                        .replacingOccurrences(of: " ", with: "_")
                    ExportManager.saveToFile(
                        content: preview,
                        defaultName: defaultName,
                        fileExtension: selectedFormat.fileExtension
                    )
                    dismiss()
                } label: {
                    Label("Save File…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Save the \(selectedFormat.rawValue) export to a .\(selectedFormat.fileExtension) file")
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 600, height: 520)
        // The sheet is transient chrome → glass, collapsing to a solid fill
        // under Reduce Transparency / Increase Contrast.
        .readerGlassBackground(reduceTransparency: reduceTransparency,
                               contrast: contrast,
                               cornerRadius: DesignTokens.Radius.xl)
        .onChange(of: selectedFormat) {
            copied = false
            updatePreview()
        }
        .onAppear {
            updatePreview()
        }
    }

    // MARK: - Format Picker

    /// A labelled radio group. Each row names the format, its file extension,
    /// and what it's good for — far clearer than three bare segmented labels.
    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Format")
                .eyebrowStyle()
                .accessibilityHidden(true)

            Picker("Export format", selection: $selectedFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Label {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(format.rawValue)
                            Text(formatBlurb(format))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: formatIcon(format))
                    }
                    .tag(format)
                    .accessibilityLabel("\(format.rawValue). \(formatBlurb(format))")
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("Export format")
        }
    }

    private func formatIcon(_ format: ExportFormat) -> String {
        switch format {
        case .markdown:  return "text.badge.star"
        case .plainText: return "doc.plaintext"
        case .json:      return "curlybraces"
        }
    }

    private func formatBlurb(_ format: ExportFormat) -> String {
        switch format {
        case .markdown:  return "Formatted headings & speaker labels — great for notes apps (.md)"
        case .plainText: return "Speaker-prefixed lines, no formatting (.txt)"
        case .json:      return "Structured data with timestamps for tooling (.json)"
        }
    }

    // MARK: - Private Helpers

    /// Generates the export string for the currently selected format.
    private func updatePreview() {
        preview = ExportManager.export(
            session: session,
            segments: segments,
            format: selectedFormat
        )
    }
}
