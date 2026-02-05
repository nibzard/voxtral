# Voxtral Menu Bar Transcriber - Specification

## Summary
A macOS menu bar app that records microphone audio, transcribes locally on Apple Silicon with a highly optimized on-device model, and writes the transcript to a Markdown file in a user-selected folder. The app is always available in the menu bar, uses a minimal popover UI, and supports an in-app keyboard shortcut to start/stop recording.

## Goals
- One-click record/stop from the menu bar.
- Local-only transcription with no network dependency during operation.
- Minimal UI and zero configuration required to get a Markdown file output.
- Performance optimized for Apple Silicon using MLX and Metal acceleration.
- Opinionated defaults: keep model choice internal so users never need to decide.
- Optional post-processing rewrite using Gemini when an API key is provided.

## Non-Goals
- Cloud transcription or account features.
- Advanced editing or formatting UI inside the app.
- Multi-user or multi-device sync.
- User-facing model selection or tuning.
- General-purpose AI chat or multi-prompt workflows.

## Jobs To Be Done (JTBD)
- As a user, I want to quickly start and stop recording from the menu bar so I can capture spoken notes without breaking my flow.
- As a user, I want transcripts saved automatically to my chosen folder as Markdown so I can use them in my notes or docs.
- As a user, I want the app to be private and offline so my audio never leaves my machine.

## Primary Use Cases
- Voice notes for meetings and personal logs.
- Live transcription while drafting summaries.
- Quick capture of ideas to a Markdown log file.

## User Journey
1. Install the app from a GitHub Release DMG or ZIP.
2. Launch the app; it appears in the menu bar (no Dock icon).
3. On first run, the app prompts for an output folder and microphone permission.
4. User clicks Record (or uses the in-app shortcut) to start transcription.
5. The app creates a new Markdown file and starts writing transcript lines live.
6. User clicks Stop to finalize the file.
7. User opens the output folder directly from the menu.

## UX and UI
### Menu Bar Item
- Always visible in the menu bar.
- Icon states: idle, recording, error.
- Click opens a small popover.

### Popover Contents
- Record/Stop toggle button.
- Status text (Idle, Initializing, Recording, Transcribing, Error).
- Output folder path with a Change button.
- Open Output Folder action.
- Quit action.
- No model selection or tuning controls (opinionated defaults).

### Preferences (Minimal)
- Gemini API key field (stored in Keychain).
- Rewrite on stop toggle (visible only when API key is present).
- No prompt editor (single internal prompt).

### Keyboard Shortcut
- In-app shortcut for Record/Stop, active when the app is active.
- Default: Command+Shift+R.

## Functional Requirements
- Record microphone input and transcribe in real time.
- Write output to a Markdown file in a user-selected folder.
- Persist output folder selection across restarts.
- Handle start/stop cleanly, with audio and transcription shutdown.
- Keep the backend warm between sessions for fast start.
- If Gemini API key is provided, send the final transcript to Gemini Flash for a single-pass rewrite and overwrite/append the Markdown output.

## Output Format (Markdown)
- File name: `YYYY-MM-DD_HHMMSS_transcript.md`.
- UTF-8 encoded.
- Structure:
  - Title line with session date/time.
  - Metadata block with device, model, and app version.
  - Transcript lines with timestamps in ascending order.

Example:
```
# Transcript - 2026-02-05 14:32

- Device: MacBook Pro (Apple Silicon)
- Model: Voxtral-Mini-4B-Realtime-2602
- App: Voxtral Menu Bar Transcriber 0.1.0

[00:00.240] First spoken line...
[00:02.960] Next line...
```

### Optional Rewrite Output
- If enabled, append a rewritten section or replace the raw transcript (decision: replace by default).
- The rewrite should fix obvious errors and improve formatting while preserving meaning.
- Keep Markdown structure (headings, bullets) and do not invent new facts.

## Performance Requirements
- Target end-to-end latency under 500ms in steady state on Apple Silicon.
- Maintain real-time transcription without audio buffer underruns.
- Minimize CPU usage during idle by keeping the backend paused or warmed.

## Architecture Overview
- UI App: SwiftUI + AppKit status item.
- Audio Capture: AVAudioEngine with an input tap feeding a ring buffer.
- Streaming Pipeline: audio frames -> resample to 16 kHz mono -> chunk -> send to backend.
- Transcription Backend: local service running the Voxtral model with MLX/Metal acceleration.
- Storage: writes Markdown to user-selected folder using security-scoped bookmarks.
- Model abstraction layer: backend loads a configured model via a stable internal interface so models can be swapped without UI changes.
- Rewrite Service: optional post-processing call to Gemini Flash using HTTPS when API key is present.

## Low-Level Implementation

### App Structure
- `MenuBarApp`: App entry point, creates status item and popover.
- `RecordController`: owns audio engine lifecycle and start/stop control.
- `TranscriptionClient`: manages IPC to the backend service.
- `OutputWriter`: streams transcript lines to a Markdown file.
- `Preferences`: stores output folder bookmark and last used settings.

### Audio Pipeline
- Use `AVAudioEngine` input node tap to capture PCM.
- Convert to 16 kHz mono float PCM.
- Chunk into 20 ms frames (320 samples at 16 kHz).
- Push frames to the backend on a background queue.
- Drop or backpressure if the backend queue exceeds a threshold.

### Backend Service
#### Delivery
- Bundle the backend binary inside the app bundle (offline-first).
- On first launch, copy the backend binary to `~/Library/Application Support/Voxtral/backend/` and execute from there.
- If the copied binary is missing or fails checksum/execute, recopy from the app bundle. No network download for the backend.

#### Launch
- Launch via `Process` on app start and keep it running.
- Default to a fixed localhost port (e.g., 8765). Allow override via env var `VOXTRAL_PORT` for dev/test.

#### IPC Protocol (WebSocket)
- Transport: WebSocket over `ws://127.0.0.1:${PORT}/v1/transcribe`.
- Control messages: JSON (UTF-8).
- Audio frames: binary messages containing raw PCM frames.

Client -> Backend control messages:
```
{"type":"start","session_id":"<uuid>","audio_format":{"sample_rate":16000,"channels":1,"encoding":"f32le","frame_samples":320},"transcription_delay_ms":480,"language":"auto"}
{"type":"stop","session_id":"<uuid>"}
```

Client -> Backend audio frames:
- Binary frame payload only (no headers).
- Exactly `frame_samples` samples per message (20 ms at 16 kHz).
- `f32le` encoding, mono, contiguous frames in send order.

Backend -> Client messages:
```
{"type":"ready","session_id":"<uuid>","backend_version":"<semver>"}
{"type":"status","state":"initializing|warming|running","detail":"<optional>"}
{"type":"transcript","seq":123,"start_ms":240,"end_ms":720,"text":"...","is_final":true,"confidence":0.92}
{"type":"error","code":"backend_error","message":"...","recoverable":true}
{"type":"session_end","session_id":"<uuid>","reason":"client_stop|backend_error"}
```

#### Model
- Load Voxtral-Mini-4B-Realtime-2602 in BF16.
- Use vLLM Metal with MLX as the primary backend.
- Apply model settings:
  - Temperature 0.0.
  - Transcription delay around 480 ms.
  - Max model length set to a long session default.
- Model swap strategy: a backend config file or build-time flag selects the model; no UI exposure. Keep a stable protocol so newer models can be dropped in without changing the app shell.

### Gemini Rewrite (Optional)
- Triggered only when the API key is present and rewrite is enabled.
- Use Gemini Flash (fast) with a fixed internal prompt.
- Single request on stop (not streaming).
- API call: HTTPS `streamGenerateContent` or `generateContent` endpoint.
- Prompt template (single prompt, internal):
  - "You are a transcription fixer. Correct obvious errors, fix grammar and punctuation, and format as clean Markdown. Preserve meaning. Do not add new facts. Keep the original structure when possible."
- Input: raw transcript body (without metadata header).
- Output: Markdown body.
- Store API key in macOS Keychain; never write it to disk.
- If the rewrite fails, keep the original transcript and log an error status.

### Model Assets
- Store model weights in `~/Library/Application Support/<AppName>/models`.
- First run downloads the model if not present.
- Support manual import by selecting a local model directory.
- Verify model files with a checksum before first use.

### File Output
- On Record start, open a new file and write the header.
- Flush lines as they arrive from the backend.
- On Stop, write a final newline and close file.

### Error Handling
- Microphone permission denied: show error status and a prompt to open System Settings.
- Backend fails to launch: show error status and a retry option.
- Output folder unavailable: prompt user to reselect.

## Security and Privacy
- All transcription is local by default and does not require a network.
- App Sandbox enabled.
- Entitlements: microphone access and user-selected file access.
- Use security-scoped bookmarks for the output folder.
- Optional Gemini rewrite sends transcript text to Google; require explicit user opt-in (API key + toggle).

## Packaging and Distribution
- Target: direct download from GitHub Releases.
- Code signed with Developer ID and notarized.
- Distribution artifacts: DMG and ZIP.
- Include a lightweight first-run model downloader to keep the app bundle small.

## System Requirements
- Apple Silicon Mac.
- Minimum macOS version: macOS 14.0 (Sonoma).
- Deployment target: macOS 14.0.
- Disk space: model weights size plus transcript output.

## Testing
- Unit tests for `OutputWriter` formatting and file naming.
- Integration test for audio capture pipeline at 16 kHz mono.
- Smoke test for backend start and stop.
- Manual test for permission flows and folder persistence.

## Open Questions
- Decide whether rewrite output replaces the raw transcript or is appended as a separate section.
