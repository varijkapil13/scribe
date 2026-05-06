# Scribe

A native macOS app that captures system audio + microphone to produce live meeting transcripts, then turns the meeting into structured tasks you can actually work with. Lives in its own window — start a recording, watch it transcribe, summarise, convert action items into tasks, set reminders, and search across everything.

Works with any conferencing tool (Teams, Zoom, Google Meet, phone calls, in-person meetings) because it operates at the OS audio level.

**Powered entirely by Apple Intelligence. All processing happens on-device. No audio or text ever leaves your Mac.**

## Requirements

| Requirement | Value |
|-------------|-------|
| macOS | **26** or later |
| Chip | **Apple Silicon** (M1 or later) |
| Downloads | None — all models are built into macOS |

No model downloads, no accounts, no subscriptions, no API keys.

## Features

### Transcription (Apple Speech)
- One-click recording from the toolbar (or `⇧⌘R` from anywhere)
- Live transcript inlined into the main window — no floating panels
- Captures both your microphone and system audio (remote participants)
- Speaker labels: "You" (mic) vs. "Remote" (system audio)
- On-device speech recognition via `SFSpeechRecognizer`
- Auto-detect language or pin to a specific one (English, German, French, and more)
- Pause / resume mid-session; crash-recovery sweep finalises any sessions left dangling

### Meeting Intelligence (Apple Intelligence / Foundation Models)
- **Meeting Summaries** — executive summary, key decisions, topics discussed
- **Action Item Extraction** — with assignees, deadlines, priority levels
- **Convert to Task** — one click on any action item creates a linked `TodoTask` with priority, deadline, assignee tag, and a "Source: <session>" back-link
- **Follow-Up Email Generation** — draft professional follow-up emails from summaries
- **Natural Language Q&A** — ask questions about your transcripts ("What did John say about the timeline?")
- **Smart Search** — semantic search across all transcripts

### Transcript Analysis (NaturalLanguage Framework)
- **Entity Extraction** — people, organizations, places mentioned in meetings
- **Language Detection** — identify primary and secondary languages
- **Sentiment Analysis** — overall and per-speaker sentiment scoring
- **Topic Extraction** — key topics and phrases from discussions

### Tasks (TickTick replacement, Phase 1 complete)
- Sidebar smart filters: **Inbox**, **Today**, **Upcoming**, **All**, **Completed**
- **Projects** with custom colors + SF Symbol icons; drag-to-reorder; drop a task onto a project to move it
- **Editor sheet** for priority, due date, reminder, project, notes, tags. Save / Cancel / Duplicate / Delete
- **Recurring tasks** (RRULE: `DAILY`/`WEEKLY`/`MONTHLY`, `INTERVAL`, `BYDAY`); completing one advances to the next occurrence and writes a history row
- **Natural-language quick add**: type `buy milk tomorrow 5pm #shopping +Errands !high` and the parser lifts the tag, project, priority, and date out of the title
- **Full-text search** over titles + notes via FTS5; ranked by bm25
- **Keyboard shortcuts**: `⌘N` focuses quick-add, `Space` toggles the focused row, `⌘⌫` deletes (with confirm)
- Tag chips render under task titles; conversion from action item uses assignee → tag

### Reminders (`UNUserNotificationCenter`)
- Set a reminder time on any task; macOS notification fires with two actions
- **Mark Done** completes the task in-place; **Snooze 15 min** pushes the reminder forward and re-arms
- Authorization is requested lazily (first reminder you save), not at launch
- Cancellation is automatic on delete / completion; recurring tasks re-arm against the next occurrence

### Export
- Markdown (with timestamps and speaker labels)
- Plain text
- JSON (structured, machine-readable)

### Privacy
- Transcription: Apple Speech on-device recognition
- AI features: Apple Intelligence Foundation Models — on-device
- Text analysis: NaturalLanguage framework — on-device
- No telemetry, no analytics, no cloud sync
- Data stored locally at `~/Library/Application Support/Scribe/`
- Delete individual sessions or wipe all data from within the app

## Getting Started

### Build from Source

1. **Clone the repository:**
   ```bash
   git clone https://github.com/varijkapil13/scribe.git
   cd scribe
   ```

2. **Generate the Xcode project** (requires [XcodeGen](https://github.com/yonaskolb/XcodeGen)):
   ```bash
   brew install xcodegen
   xcodegen generate
   open Scribe.xcodeproj
   ```

   Or open the SwiftPM package directly in Xcode:
   ```bash
   open Package.swift
   ```

3. **Build and run** in Xcode (`⌘R`). Scribe opens its main window.

That's it — no model downloads required. Everything runs using built-in macOS frameworks.

### Tests

Logic tests run via SwiftPM (the Xcode test scheme isn't used because the host app boots audio services on launch and the hosted test bundle crashes during bootstrap):

```bash
swift test                        # full suite
swift test --filter TaskStoreTests
```

### Permissions

Scribe needs three macOS permissions across its lifetime:

- **Microphone** — to capture your voice
- **Screen Recording** — required by macOS for system audio capture via ScreenCaptureKit (only audio is captured, never video or screen content)
- **Notifications** — only requested the first time you save a task with a reminder

## Usage

1. **Start recording** — toolbar Record button or `⇧⌘R` from anywhere
2. **Watch live transcript** — the live view replaces the detail pane while a session is active
3. **Pause / Resume** — pause without ending the session
4. **Stop** — saves the transcript; sidebar selects the just-finished session so you can summarise it in one click
5. **Summarize** — generate an AI summary with action items using Apple Intelligence
6. **Analyze** — extract entities, topics, and sentiment from the transcript
7. **Convert action items** — tap "Convert to task" on any action item row to create a linked task
8. **Manage tasks** — open Tasks → Inbox / Today / Upcoming / All / Completed in the sidebar; type into the quick-add field with NL syntax (`#tag`, `+Project`, `!high`, dates)
9. **Get reminded** — set a reminder time in the task editor and macOS will surface a notification with Mark Done / Snooze 15 min actions
10. **Search** — focus the task list's search field (or `⌘F`) for FTS5 ranked search across titles and notes
11. **Export** — select a session and export as Markdown, plain text, or JSON

## Architecture

```
Scribe.app (Swift 6 / SwiftUI / macOS 26)
├── Main Window (NavigationSplitView: sidebar + detail)
│   ├── Live Session view (during recording)
│   ├── Transcript Detail view (segments / summary / action items / insights)
│   └── Task list view (smart filters, projects, search)
│
├── Audio Capture
│   ├── MicrophoneCapture (AVAudioEngine)
│   └── SystemAudioCapture (ScreenCaptureKit)
│
├── Intelligence
│   ├── SpeechRecognizerEngine (SFSpeechRecognizer — transcription)
│   ├── MeetingSummarizer (FoundationModels — summaries & action items)
│   ├── SmartSearchEngine (FoundationModels — semantic search & Q&A)
│   └── TranscriptAnalyzer (NaturalLanguage — entities, sentiment, topics)
│
├── Tasks
│   ├── RecurrenceRule + RecurrenceEngine (minimal RRULE)
│   ├── QuickAddParser (#tag / +project / !priority / dates)
│   └── TaskReminderScheduler (UNUserNotificationCenter)
│
├── Storage (SQLite + FTS5 via GRDB.swift, migrations v1–v5)
│   ├── sessions, segments, segments_fts
│   ├── meeting_summaries, action_items, extracted_entities
│   ├── projects, tasks, task_tags, task_completions
│   └── tasks_fts (full-text index over title + notes)
│
└── Export (Markdown, Plain Text, JSON)
```

### Apple Frameworks

| Framework | Purpose |
|-----------|---------|
| **Speech** (`SFSpeechRecognizer`) | On-device speech-to-text transcription |
| **FoundationModels** | Meeting summaries, action items, smart search, Q&A |
| **NaturalLanguage** | Entity extraction, language detection, sentiment analysis |
| **ScreenCaptureKit** | System audio capture (remote participants) |
| **AVFoundation** | Microphone capture and audio processing |
| **UserNotifications** | Task reminders + custom action handlers |
| **AppKit** | Window lifecycle, alerts, system-settings deep-links |
| **SwiftUI** | Main window, sidebar, transcript viewer, task list, editor sheets |

### Dependencies

| Package | Purpose |
|---------|---------|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite database with FTS5 full-text search |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global keyboard shortcut for start/stop recording |

### Project Structure

```
Scribe/
├── App/                    # App entry point, delegate, central state
├── Audio/                  # Mic + system audio capture, buffering
├── Intelligence/           # Apple Speech, Foundation Models, NaturalLanguage
├── Storage/                # SQLite models, database manager, transcript + task stores
├── Tasks/                  # Recurrence engine, NL quick-add parser, reminder scheduler
├── Export/                 # Markdown, plain text, JSON exporters
├── UI/
│   ├── MainWindow/         # Sidebar, live session view, window-level coordination
│   ├── TranscriptViewer/   # Session detail, summary tab, action items, insights
│   ├── Tasks/              # Task list, editor sheet, project editor, drag payloads
│   ├── DesignSystem/       # Tokens, chips, badges, hero record button
│   └── Settings/           # Audio, intelligence, storage, shortcut config
├── Utilities/              # Permissions, keyboard shortcuts, logging, extensions
└── Resources/              # Info.plist, entitlements, asset catalogs
```

### Data Storage

All data is stored locally at `~/Library/Application Support/Scribe/scribe.db`. Schema evolves through additive GRDB migrations.

| Table | Contents |
|-------|----------|
| `sessions` | Recording metadata (title, date, duration, language, tags) |
| `segments` | Timestamped transcript segments with speaker labels |
| `segments_fts` | FTS5 full-text search index over segments |
| `meeting_summaries` | AI-generated summaries with key decisions and topics |
| `action_items` | Extracted action items with assignees and completion tracking |
| `extracted_entities` | Cached NLP entity extraction results |
| `projects` | Task projects (name, color, icon, sort order) |
| `tasks` | Task rows (title, notes, project, priority, due/remind/recurrence, source-link to session/action_item) |
| `task_tags` | Many-to-many task ↔ tag |
| `task_completions` | Completion history (used for recurring tasks) |
| `tasks_fts` | FTS5 full-text search index over task title + notes |

### Roadmap

`PLAN.md` is the source of truth for what's done and what's next. **Phase 1 (Tasks, TickTick replacement)** is complete. **Phase 2 (Notes, Obsidian replacement)** — markdown editor, wiki-links + backlinks, daily notes, universal search, optional graph view — is up next.

## Privacy

Everything runs locally on your Mac:

- **No audio** is sent to any server
- **No text** is sent to any server
- **No telemetry** or analytics of any kind
- **No cloud sync** — data stays on your machine
- **No accounts** or API keys required
- User controls all data storage and deletion

## License

Private / Internal use.
