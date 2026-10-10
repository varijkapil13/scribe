# Scribe

A native macOS app that captures system audio + microphone to produce live meeting transcripts, then turns the meeting into structured tasks you can actually work with. Lives in its own window — start a recording, watch it transcribe, summarise, convert action items into tasks, set reminders, and search across everything.

Works with any conferencing tool (Teams, Zoom, Google Meet, phone calls, in-person meetings) because it operates at the OS audio level.

**Powered entirely by Apple Intelligence. All processing happens on-device. No audio or text ever leaves your Mac.**

## Requirements

| Requirement | Value |
|-------------|-------|
| macOS | **27** or later |
| Chip | **Apple Silicon** (M1 or later) |
| Downloads | None. Speech and Apple Intelligence models are built into macOS, and the speaker-separation model (about 22 MB) ships inside release builds |

No accounts, no subscriptions, no API keys.

## Features

### Transcription (Apple Speech)
- One-click recording from the toolbar (or `⇧⌘R` from anywhere)
- Live transcript streams inline above your meeting note while you record
- Captures both your microphone and system audio (remote participants)
- Speaker labels: "You" (mic) vs. "Remote" (system audio)
- On-device speech recognition via `SFSpeechRecognizer`
- Auto-detect language or pin to a specific one (English, German, French, and more)
- Pause / resume mid-session; crash-recovery sweep finalises any sessions left dangling

### Meeting Auto-Detection
- Notices when Zoom, Teams, Slack huddles, FaceTime, Webex, Discord, Google Meet (in a browser) and other call apps start using the microphone
- **Ask me** (default): a notification with **Start Recording** appears; or choose **Start recording automatically**, which records into a new "Zoom meeting on …" note
- When the call releases the mic, Scribe can **ask** to stop (default), **stop automatically**, or keep recording
- Debounced (mic held ≥ 3 s to start, released ≥ 15 s to end) so brief mic probes and device switches don't trigger it
- Only checks *which app* holds the mic (CoreAudio process list) and never listens until you record
- Settings → General → Meeting detection, which also has **Open Scribe at login** so detection is always on

### Dictation (any app)
- Press **⌥⌘D** (configurable), speak, and Scribe types the text wherever your cursor is: Slack, Mail, your editor, a Scribe note
- Two modes: press to start / press again to insert, or hold while speaking and release to insert
- Floating pill shows live text and a level meter without stealing focus
- Cleanup: removes filler words, and optionally polishes punctuation and casing with Apple Intelligence (on-device; falls back to the plain transcript)
- Pastes via ⌘V, which needs Accessibility access. Without it the text is copied to the clipboard
- Independent of meeting recording, so you can dictate while a meeting is being transcribed

### Menu Bar
- Status icon shows idle / recording / paused / dictating
- Start/stop/pause recording, record a detected meeting, start dictation, paste the last dictation, jump to Today or Settings
- While the icon is shown, closing the main window keeps Scribe running so detection, dictation and reminders keep working (Settings → General → Menu bar & login)

### Calendar (optional)
- Turn it on in Settings → Calendar. It reads the calendars already on your Mac via EventKit, with no account sign-in
- Notes are named after the meeting ("Weekly Sync — Oct 9, 2026") and start with attendees, agenda and the meeting link
- A notification one minute before meetings with 2+ attendees offers **Start Recording** or **Join & Record**
- Detected calls are matched to the calendar event, and the menu bar lists upcoming meetings

### Speakers
- **Telling remote speakers apart:** after a meeting, Scribe splits "Remote" into Speaker 1, 2, 3… on your Mac (pyannote via [FluidAudio](https://github.com/FluidInference/FluidAudio), Core ML)
- Names are suggested from calendar attendees and the conversation ("Thanks, Priya"), and are only applied when the name is an attendee or is actually said in the meeting
- Rename any speaker per transcript, or reassign lines to someone else
- "Your name" defaults to your macOS account name

### Templates, Enhance & Recipes
- Summary templates (General, 1:1, Standup, Interview, Sales call, Brainstorm) are markdown files in `<vault>/Templates/Summaries/`, picked automatically from the meeting title
- **Re-summarize with…** any template. The summary is written into a marked block in the note, so your own text is never touched
- **Enhance notes** expands your typed notes with details from the transcript, with a preview you accept or discard
- Recipes (saved prompts) for a follow-up email, decisions and owners, and risks and open questions, or add your own in `<vault>/Templates/Recipes/`

### Ask Scribe & People
- **Ask Scribe:** chat across all meetings, a notebook, a person, or the last 7/30 days. Answers cite clickable `[[sources]]`
- **People:** everyone mentioned or speaking across meetings, with their meetings and open tasks, plus one-click person notes
- MCP tools: `ask_meetings`, `search_meetings`, `list_people`, `get_person`

### Vocabulary & Hooks
- A custom vocabulary (`~/Library/Application Support/Scribe/vocabulary.md`) improves recognition of names and jargon and fixes "heard as → spelled" mistakes
- Post-meeting hooks run your own scripts with the meeting as JSON on stdin (Slack, Notion, Linear… with no Scribe cloud)

### Audio
- Optionally keep each meeting's audio (mic and remote as separate files), deleted after 7/30/90 days or kept forever
- Built-in player: click any timestamp to hear that moment, at 1×/1.5×/2× speed
- Echo cancellation for meetings without headphones

### Meeting Notes (notes own transcripts)
- Every recording lives inside a Note — there is no standalone "transcript" surface
- Press Record with a note open → the new session binds to that note
- Press Record from anywhere else → a "Meeting on …" note is auto-created and selected
- A Note's detail view shows a strip of session chips; click one to expand its **Summary**, **Action items**, and **Mentioned** entities inline
- "+ New recording" button on the strip starts another session inside the same note (notes can own many recordings)
- "Open transcript" sheet from the auto-section opens the rich segment view (select / move segments, re-summarise, export transcript) without leaving the note
- Deleting a note also deletes its recordings; converted tasks survive with their session link cleared

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
- **Notes** as Markdown — title, body, plus a "## Linked recordings" tail with each session's summary, action items, and mentioned entities
- **Transcripts** (from the in-note "Open transcript" sheet) as Markdown (timestamps + speaker labels), Plain text, or JSON

### Privacy
- Transcription: Apple Speech on-device recognition
- AI features: Apple Intelligence Foundation Models — on-device
- Text analysis: NaturalLanguage framework — on-device
- Speaker separation: FluidAudio Core ML models — on-device
- Calendar: read from the Mac's own calendars via EventKit, only after you turn it on
- No telemetry, no analytics, no cloud sync
- Data stored locally at `~/Library/Application Support/Scribe/`
- Delete individual sessions or wipe all data from within the app

## Getting Started

### Install with Homebrew

```bash
brew install --cask varijkapil13/tap/scribe
```

Updates arrive with `brew upgrade`. The cask installs the latest GitHub Release. Builds are not notarized yet, so the cask clears the download's quarantine flag for you. `brew uninstall --zap scribe` also removes app data, but never your notes vault.


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

1. **Start recording** — toolbar Record button or `⇧⌘R` from anywhere. With a note open, the session binds to that note; otherwise a "Meeting on …" note is auto-created and selected.
2. **Take notes while you record** — the live transcript streams in a pane above the note's freeform editor; type alongside it.
3. **Pause / Resume** — pause without ending the session.
4. **Stop** — saves the transcript inside the note. The session's chip appears in the strip; click it to expand summary / action items / entities.
5. **Summarize / Analyze** — generated automatically (per Settings) or on-demand from the per-session auto-section.
6. **Convert action items** — tap "Convert to task" on any action item row to create a linked task.
7. **Open transcript** — click "Open transcript" in the auto-section to view raw segments in a sheet (select / move / re-summarise / export transcript).
8. **Manage tasks** — open Tasks → Inbox / Today / Upcoming / All / Completed in the sidebar; type into the quick-add field with NL syntax (`#tag`, `+Project`, `!high`, dates).
9. **Get reminded** — set a reminder time in the task editor and macOS will surface a notification with Mark Done / Snooze 15 min actions.
10. **Search** — `⌘⇧F` opens a universal search across notes, tasks, and transcript content; transcript hits navigate to their owning note.
11. **Export** — Export a note as Markdown (with the "Linked recordings" tail) from the note's toolbar; export a single transcript as Markdown / Plain text / JSON from the "Open transcript" sheet.

## Architecture

```
Scribe.app (Swift 6 / SwiftUI / macOS 27)
├── Main Window (NavigationSplitView: sidebar + detail)
│   ├── Live Session view (when recording from no-note contexts)
│   ├── Note Detail view (freeform editor + Sessions strip + per-session auto-section + inline live pane)
│   │   └── Transcript Detail sheet (raw segments / select+move / export — reached from "Open transcript")
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
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | On-device speaker diarization (pyannote community-1 models, CC BY 4.0). Fetch the models into release builds with `scripts/fetch-diarizer-models.sh` |

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
