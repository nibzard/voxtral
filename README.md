# Voxtral Menu Bar Transcriber

A macOS menu bar app that records microphone audio, transcribes locally, and writes a live Markdown transcript to a folder you choose.

**Requirements**
- Apple Silicon Mac.
- macOS 14.0 or later.

**Install**
1. Download the latest DMG or ZIP from GitHub Releases.
2. If using the DMG, open it and drag `Voxtral Menu Bar Transcriber.app` to Applications.
3. Launch the app. It appears in the menu bar (no Dock icon).

**First Run & Permissions**
- macOS will prompt for microphone access.
- The app will ask you to choose an output folder and saves a security-scoped bookmark so it can keep writing there.
- You can change the output folder anytime from the popover.

**Recording**
1. Click the menu bar icon and press Record (or use Command+Shift+R when the app is active).
2. Speak; transcript lines stream into the output file while recording.
3. Click Stop to finalize the file.

**Output Files**
- Files are named `YYYY-MM-DD_HHMMSS_transcript.md`.
- Each file includes a header and timestamped transcript lines.
- Use the "Open Output Folder" action to jump to the folder.

**Privacy**
- Transcription is local and offline by default; audio never leaves your Mac.
- The app only writes to the folder you select.

**Optional Gemini Rewrite**
- Add a Gemini API key in Preferences to enable the rewrite toggle.
- When enabled, the app sends the transcript text (not audio) to Google Gemini over HTTPS after you stop, then replaces the transcript with the rewritten version.
- If the rewrite fails, the original transcript is kept.
