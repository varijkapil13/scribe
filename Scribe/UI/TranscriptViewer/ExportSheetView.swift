import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Sheet view that lets the user choose an export format, preview the
/// output, and save or copy the transcript.
struct ExportSheetView: View {

    @Environment(\.dismiss) var dismiss

    let session: Session
    let segments: [Segment]

    @State var selectedFormat: ExportFormat = .markdown
    @State var preview: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Export Transcript")
                .font(.headline)

            Picker("Format", selection: $selectedFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)

            // Preview area
            ScrollView {
                Text(preview)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 300)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Copy to Clipboard") {
                    #if canImport(AppKit)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(preview, forType: .string)
                    #endif
                }

                Button("Save File...") {
                    let defaultName = session.title
                        .replacingOccurrences(of: " ", with: "_")
                    ExportManager.saveToFile(
                        content: preview,
                        defaultName: defaultName,
                        fileExtension: selectedFormat.fileExtension
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 600, height: 500)
        .onChange(of: selectedFormat) { _ in
            updatePreview()
        }
        .onAppear {
            updatePreview()
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
