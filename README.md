# Scribe

A native macOS menu-bar application that captures system audio and microphone input to produce live meeting transcripts. Works with any conferencing tool (Teams, Zoom, Google Meet, phone calls, in-person meetings) by operating at the OS audio level.

## Features

- **One-click recording** from the macOS menu bar
- **Live transcription overlay** — floating panel shows transcript in real time
- **Dual audio capture** — microphone (you) + system audio (remote participants)
- **Fully local/offline** — all transcription via [whisper.cpp](https://github.com/ggerganov/whisper.cpp), no audio leaves your device
- **Speaker labels** — segments labeled as "You" (mic) or "Remote" (system audio)
- **Searchable history** — SQLite FTS5 full-text search across all transcripts
- **Export** — Markdown, plain text, and JSON formats
- **Session management** — name, tag, and browse past transcripts
- **Global keyboard shortcut** — Cmd+Shift+R to toggle recording
- **Privacy first** — no telemetry, no cloud, all data stored locally

## Requirements

| Requirement    | Value                                             |
|----------------|---------------------------------------------------|
| macOS          | 13.0 (Ventura) or later                          |
| RAM            | 8 GB minimum (16 GB recommended for large model) |
| Disk           | ~2 GB for app + medium model                     |
| Chip           | Apple Silicon recommended (Intel supported)       |

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
   ```
   
   Or open the package directly in Xcode:
   ```bash
   open Package.swift
   ```

3. **Build and run** in Xcode (Cmd+R). The app appears in the menu bar.

4. **Download a Whisper model** — on first launch, Settings opens automatically. Download either:
   - **Medium** (~1.5 GB) — good balance of speed and accuracy
   - **Large v3 Turbo** (~3 GB) — best accuracy, recommended for Apple Silicon

### Permissions

Scribe needs two macOS permissions on first use:

- **Microphone** — to capture your voice
- **Screen Recording** — required by macOS for system audio capture (only audio is captured, not video)

## Architecture

```
Scribe/
├── App/                    # App entry point, delegate, central state
├── Audio/                  # Mic capture (AVAudioEngine), system audio (ScreenCaptureKit)
├── Transcription/          # whisper.cpp integration, chunked processing
├── Storage/                # SQLite + GRDB, FTS5 search, data models
├── Export/                 # Markdown, plain text, JSON exporters
├── Models/                 # Whisper model download and management
├── UI/
│   ├── MenuBar/            # NSStatusItem, dropdown menu
│   ├── Overlay/            # Floating NSPanel with live transcript
│   ├── TranscriptViewer/   # Session history, detail view, search
│   └── Settings/           # Audio, model, storage, shortcut configuration
├── Utilities/              # Permissions, keyboard shortcuts, extensions
└── Resources/              # Info.plist, entitlements, asset catalogs
```

### Technology Stack

| Component        | Technology                     |
|------------------|--------------------------------|
| Language         | Swift 5.9+                     |
| UI               | SwiftUI + AppKit (menu bar)    |
| Mic capture      | AVAudioEngine                  |
| System audio     | ScreenCaptureKit               |
| Transcription    | whisper.cpp (Core ML / Metal)  |
| Database         | SQLite via GRDB.swift + FTS5   |
| Shortcuts        | KeyboardShortcuts              |

### Data Storage

All data is stored locally at `~/Library/Application Support/Scribe/`:

```
~/Library/Application Support/Scribe/
├── scribe.db          # SQLite database (sessions, segments, FTS index)
└── models/            # Downloaded Whisper GGML models
    ├── ggml-medium.bin
    └── ggml-large-v3-turbo.bin
```

## Usage

1. **Start recording** — click the waveform icon in the menu bar and select "Start Transcription" (or press Cmd+Shift+R)
2. **View live transcript** — a floating overlay panel shows segments as they're transcribed
3. **Pause/Resume** — pause without ending the session
4. **Stop** — ends the session and saves the transcript
5. **Browse history** — open "View Transcripts" to search and review past sessions
6. **Export** — select a session and export as Markdown, plain text, or JSON

## Privacy

- All audio processing happens on-device via whisper.cpp
- No audio or text is sent to any server
- No telemetry or analytics
- User controls all data storage and deletion

## License

MIT
