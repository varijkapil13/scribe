import SwiftUI

/// Content of the Quick Capture panel: mode switcher (⌘1/⌘2/⌘3), one text
/// field, the task preview chips, and the save hints.
struct QuickCaptureView: View {
    @ObservedObject var model: QuickCaptureModel
    @ObservedObject var dictation: QuickCaptureDictation
    @FocusState private var fieldFocused: Bool
    @Environment(\.openWindow) private var openWindow

    static let width: CGFloat = 620

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header
            field
            if model.mode == .task {
                taskPreview
            }
            statusLine
            footer
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: Self.width, alignment: .topLeading)
        .scribeFloatingGlass(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .onExitCommand { model.cancel() }
        .onAppear {
            model.openWindowAction = openWindow
            fieldFocused = true
        }
        .onChange(of: model.focusToken) { _, _ in
            fieldFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Capture")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(QuickCaptureMode.allCases) { mode in
                modeButton(mode)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            if model.isDictationAvailable {
                micButton
            }
            // Esc. Invisible: the hint lives in the footer. A real button
            // (not only `onExitCommand`) so Esc works while the field edits.
            Button("Close") { model.cancel() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func modeButton(_ mode: QuickCaptureMode) -> some View {
        let selected = model.mode == mode
        let traits: AccessibilityTraits = selected ? .isSelected : []
        return Button {
            model.select(mode)
        } label: {
            Label(mode.title, systemImage: mode.systemImage)
                .font(.system(.callout, weight: selected ? .semibold : .regular))
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .background(
                    Capsule().fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(mode.shortcutDigit))), modifiers: .command)
        .help("\(mode.accessibilityTitle) (⌘\(mode.shortcutDigit))")
        .accessibilityLabel(mode.accessibilityTitle)
        .accessibilityAddTraits(traits)
    }

    private var micButton: some View {
        let listening = dictation.isActive
        return Button {
            model.toggleDictation()
        } label: {
            Group {
                if dictation.phase == .preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: listening ? "mic.fill" : "mic")
                        .foregroundStyle(listening ? Color.red : Color.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("d", modifiers: .command)
        .help(listening ? "Stop dictating (⌘D)" : "Dictate (⌘D)")
        .accessibilityLabel(listening ? "Stop dictating" : "Dictate")
    }

    // MARK: - Field

    private var field: some View {
        TextField(model.mode.placeholder, text: $model.text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 20))
            .lineLimit(1...6)
            .focused($fieldFocused)
            .onSubmit { model.save(openAfter: false) }
            .accessibilityLabel(model.mode.accessibilityTitle)
    }

    // MARK: - Task preview

    @ViewBuilder
    private var taskPreview: some View {
        let chips = model.chips
        if !chips.isEmpty || model.taskTitlePreview != nil {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let title = model.taskTitlePreview {
                    Text(title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                        .layoutPriority(-1)
                }
                ForEach(chips) { chip in
                    QuickCaptureChipView(chip: chip)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Status / footer

    @ViewBuilder
    private var statusLine: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if case .failed(let message) = dictation.phase {
            Label(message, systemImage: "mic.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if dictation.phase == .listening {
            Label("Listening… press ⌘D to stop", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Text("⌘1 Note · ⌘2 Task · ⌘3 Today · esc to close")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Save & Open") { model.save(openAfter: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSave)
            Button("Save") { model.save(openAfter: false) }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .scribeGlassButton(prominent: true)
        }
        .controlSize(.small)
    }
}

/// One recognised piece of task metadata.
struct QuickCaptureChipView: View {
    let chip: QuickCaptureChip

    var body: some View {
        Label(chip.text, systemImage: chip.systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 0.5))
            .fixedSize()
    }

    private var tint: Color {
        switch chip.kind {
        case .due:            return .blue
        case .priority:
            switch chip.text {
            case TodoTask.Priority.high.rawValue:   return DesignTokens.Palette.priorityHigh
            case TodoTask.Priority.medium.rawValue: return DesignTokens.Palette.priorityMedium
            default:                                return DesignTokens.Palette.priorityLow
            }
        case .tag:            return .purple
        case .project:        return .teal
        case .unknownProject: return .secondary
        }
    }
}

/// Small confirmation pill shown after a save.
struct QuickCaptureToastView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .scribeFloatingGlass(in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .combine)
    }
}
