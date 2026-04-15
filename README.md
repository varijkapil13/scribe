# Scribe

A native macOS menu-bar application that captures system audio and microphone input to produce live meeting transcripts. Works with any conferencing tool (Teams, Zoom, Google Meet, phone calls, in-person meetings) because it operates at the OS audio level.

**Powered entirely by Apple Intelligence. All processing happens on-device. No audio or text ever leaves your Mac.**

## Requirements

| Requirement | Value |
|-------------|-------|
| macOS | **26** or later |
| Chip | **Apple Silicon** (M1 or later) |
| Downloads | None -- all models are built into macOS |

No model downloads, no accounts, no subscriptions, no API keys.

## Features

### Transcription (Apple Speech)
- One-click recording from the menu bar
- Live transcript in a floating overlay window
- Captures both your microphone and system audio (remote participants)
- Speaker labels: "You" (mic) vs. "Remote" (system audio)
- On-device speech recognition via `SFSpeechRecognizer`
- Auto-detect language or pin to a specific one (English, German, French, and more)

### Meeting Intelligence (Apple Intelligence / Foundation Models)
- **Meeting Summaries** -- executive summary, key decisions, topics discussed
- **Action Item Extraction** -- with assignees, deadlines, and priority levels
- **Follow-Up Email Generation** -- draft professional follow-up emails from summaries
- **Natural Language Q&A** -- ask questions about your transcripts ("What did John say about the timeline?")
- **Smart Search** -- semantic search across all transcripts

### Transcript Analysis (NaturalLanguage Framework)
- **Entity Extraction** -- people, organizations, places mentioned in meetings
- **Language Detection** -- identify primary and secondary languages
- **Sentiment Analysis** -- overall and per-speaker sentiment scoring
- **Topic Extraction** -- key topics and phrases from discussions

### Export
- Markdown (with timestamps and speaker labels)
- Plain text
- JSON (structured, machine-readable)

### Privacy
- Transcription: Apple Speech on-device recognition
- AI features: Apple Intelligence Foundation Models -- on-device
- Text analysis: NaturalLanguage framework -- on-device
- No telemetry, no analytics, no cloud sync
- Data stored locally at `~/Library/Application Support/Scribe/`
- Delete individual sessions or wipe all data from within the app

## Getting Started

### Build from Source

1. **Clone the repository:**
   ```bash
   git clone https://github.com/varijkapil13/meeting-transcript-mac.git
   cd meeting-transcript-mac
   ```

2. **Generate the Xcode project** (requires [XcodeGen](https://github.com/yonaskolb/XcodeGen)):
   ```bash
   brew install xcodegen
   xcodegen generate
   open Scribe.xcodeproj
   ```

   Or open the package directly in Xcode:
   ```bash
   open Package.swift
   ```

3. **Build and run** in Xcode (Cmd+R). The app appears in the menu bar.

That's it -- no model downloads required. Everything runs using built-in macOS frameworks.

### Permissions

Scribe needs two macOS permissions on first use:

- **Microphone** -- to capture your voice
- **Screen Recording** -- required by macOS for system audio capture via ScreenCaptureKit (only audio is captured, never video or screen content)

## Usage

1. **Start recording** -- click the waveform icon in the menu bar and select "Start Transcription" (or press Cmd+Shift+R)
2. **View live transcript** -- a floating overlay panel shows segments as they're transcribed
3. **Pause/Resume** -- pause without ending the session
4. **Stop** -- ends the session and saves the transcript
5. **Summarize** -- generate an AI summary with action items using Apple Intelligence
6. **Analyze** -- extract entities, topics, and sentiment from the transcript
7. **Browse history** -- open "View Transcripts" to search and review past sessions
8. **Smart search** -- ask natural language questions across all your transcripts
9. **Export** -- select a session and export as Markdown, plain text, or JSON

## Architecture

```
Scribe.app (Swift 6 / SwiftUI / macOS 26)
├── Menu Bar UI (AppKit NSStatusItem)
├── Floating Overlay (NSPanel + SwiftUI)
├── Transcript Viewer (SwiftUI NavigationSplitView)
│
├── Audio Capture
│   ├── MicrophoneCapture (AVAudioEngine)
│   └── SystemAudioCapture (ScreenCaptureKit)
│
├── Intelligence
│   ├── SpeechRecognizerEngine (SFSpeechRecognizer -- transcription)
│   ├── MeetingSummarizer (FoundationModels -- summaries & action items)
│   ├── SmartSearchEngine (FoundationModels -- semantic search & Q&A)
│   └── TranscriptAnalyzer (NaturalLanguage -- entities, sentiment, topics)
│
├── Storage (SQLite + FTS5 via GRDB.swift)
│   ├── sessions, segments, segments_fts
│   ├── meeting_summaries, action_items
│   └── extracted_entities
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
| **AppKit** | Menu bar status item, floating overlay panel |
| **SwiftUI** | Main UI, settings, transcript viewer |

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
├── Storage/                # SQLite models, database manager, transcript store
├── Export/                 # Markdown, plain text, JSON exporters
├── UI/
│   ├── MenuBar/            # NSStatusItem, dropdown menu
│   ├── Overlay/            # Floating NSPanel with live transcript
│   ├── TranscriptViewer/   # Session history, detail view, search, insights
│   └── Settings/           # Audio, intelligence, storage, shortcut config
├── Utilities/              # Permissions, keyboard shortcuts, extensions
└── Resources/              # Info.plist, entitlements, asset catalogs
```

### Data Storage

All data is stored locally at `~/Library/Application Support/Scribe/scribe.db`:

| Table | Contents |
|-------|----------|
| `sessions` | Recording metadata (title, date, duration, language, tags) |
| `segments` | Timestamped transcript segments with speaker labels |
| `segments_fts` | FTS5 full-text search index |
| `meeting_summaries` | AI-generated summaries with key decisions and topics |
| `action_items` | Extracted action items with assignees and completion tracking |
| `extracted_entities` | Cached NLP entity extraction results |

## Privacy

Everything runs locally on your Mac:

- **No audio** is sent to any server
- **No text** is sent to any server
- **No telemetry** or analytics of any kind
- **No cloud sync** -- data stays on your machine
- **No accounts** or API keys required
- User controls all data storage and deletion

## License

Private / Internal use.
