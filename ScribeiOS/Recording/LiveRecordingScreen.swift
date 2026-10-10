// ScribeiOS/Recording/LiveRecordingScreen.swift
//
// The live recording view on iPhone / iPad: elapsed time, level meter, the
// transcript as it is spoken, bookmarks, pause / resume and stop.

import SwiftUI

struct LiveRecordingScreen: View {
    let controller: MobileRecordingController
    @Environment(\.dismiss) private var dismiss

    @State private var isLabelPromptPresented = false
    @State private var bookmarkLabel = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                Divider()
                transcriptFeed
                Divider()
                controls
                    .padding()
            }
            .navigationTitle(controller.title.isEmpty ? "Recording" : controller.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Hide", systemImage: "chevron.down")
                    }
                    .accessibilityHint("The recording keeps running.")
                }
            }
            .alert("Mark moment", isPresented: $isLabelPromptPresented) {
                TextField("Label (optional)", text: $bookmarkLabel)
                Button("Mark") {
                    controller.addBookmark(label: bookmarkLabel)
                    bookmarkLabel = ""
                }
                Button("Cancel", role: .cancel) { bookmarkLabel = "" }
            } message: {
                Text("Bookmarked moments are highlighted in the summary and the meeting note.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Text(MobileRecordingTitle.elapsedLabel(seconds: controller.elapsedSeconds))
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityLabel("Elapsed time \(MobileRecordingTitle.elapsedLabel(seconds: controller.elapsedSeconds))")

            MobileLevelMeter(level: controller.level, isActive: controller.phase == .recording)
                .frame(height: 28)

            HStack(spacing: 6) {
                statusDot
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                if let input = controller.inputName {
                    Text("· \(input)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(MobileRecordingDefaults.captureModeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = controller.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        controller.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var statusDot: some View {
        switch controller.phase {
        case .recording:
            Circle().fill(.red).frame(width: 10, height: 10)
        case .paused:
            Image(systemName: "pause.fill").font(.caption).foregroundStyle(.orange)
        case .preparing, .finishing:
            ProgressView().controlSize(.small)
        case .idle:
            EmptyView()
        }
    }

    private var statusText: String {
        if let message = controller.statusMessage { return message }
        switch controller.phase {
        case .idle:      return "Not recording"
        case .preparing: return "Getting ready…"
        case .recording: return "Recording"
        case .paused:    return "Paused"
        case .finishing: return "Finishing…"
        }
    }

    // MARK: - Transcript

    private var transcriptFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if controller.lines.isEmpty, controller.pendingLine == nil, controller.partialText.isEmpty {
                        Text(controller.phase == .recording
                             ? "Listening… the transcript appears here as people speak."
                             : "The transcript appears here.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(controller.lines) { line in
                        MobileTranscriptLineView(speaker: line.speaker, startMs: line.startMs, text: line.text, isLive: false)
                    }
                    if let pending = controller.pendingLine {
                        MobileTranscriptLineView(speaker: pending.speaker, startMs: pending.startMs, text: pending.text, isLive: true)
                    }
                    if !controller.partialText.isEmpty {
                        Text(controller.partialText)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding()
            }
            .onChange(of: controller.lines.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: controller.pendingLine?.text) { _, _ in scrollToBottom(proxy) }
            .onChange(of: controller.partialText) { _, _ in scrollToBottom(proxy) }
        }
    }

    private static let bottomID = "live-transcript-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 28) {
            Button {
                controller.addBookmark(label: nil)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "bookmark.fill").font(.title2)
                    Text(controller.bookmarks.isEmpty ? "Mark" : "Mark (\(controller.bookmarks.count))")
                        .font(.caption)
                }
                .frame(width: 72)
            }
            .disabled(!controller.canBookmark)
            .contextMenu {
                Button("Mark with a Label…", systemImage: "character.cursor.ibeam") {
                    isLabelPromptPresented = true
                }
            }
            .accessibilityLabel("Mark moment")

            Button {
                Task { await controller.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(.red))
            }
            .disabled(!(controller.phase == .recording || controller.phase == .paused || controller.phase == .preparing))
            .accessibilityLabel("Stop recording")

            Button {
                controller.togglePause()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: controller.phase == .paused ? "play.fill" : "pause.fill").font(.title2)
                    Text(controller.phase == .paused ? "Resume" : "Pause").font(.caption)
                }
                .frame(width: 72)
            }
            .disabled(!(controller.phase == .recording || controller.phase == .paused))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pieces

/// One transcript paragraph: speaker + timestamp over the text.
struct MobileTranscriptLineView: View {
    let speaker: String
    let startMs: Int
    let text: String
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(speaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(SessionBookmarkFormatter.shortTimestamp(ms: startMs))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if isLive {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative)
                }
            }
            Text(text)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A row of bars that fill with the input level.
struct MobileLevelMeter: View {
    let level: Double
    let isActive: Bool

    private static let barCount = 24

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 3
            let width = max(1, (geometry.size.width - spacing * CGFloat(Self.barCount - 1)) / CGFloat(Self.barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    let threshold = Double(index) / Double(Self.barCount)
                    let lit = isActive && level > threshold
                    Capsule()
                        .fill(lit ? Color.red.opacity(0.4 + 0.6 * threshold) : Color.secondary.opacity(0.2))
                        .frame(width: width, height: geometry.size.height * (0.35 + 0.65 * barShape(index)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    /// Taller bars in the middle.
    private func barShape(_ index: Int) -> Double {
        let center = Double(Self.barCount - 1) / 2
        return 1 - abs(Double(index) - center) / (center + 1)
    }
}
