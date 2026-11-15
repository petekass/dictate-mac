# Dictate Agent Notes

Dictate is a native Swift macOS menu bar app.

## Build And Install

Use Xcode or `xcodebuild` from the repo root:

```bash
xcodebuild -project Dictate/Dictate.xcodeproj -scheme Dictate -configuration Release \
  DEVELOPMENT_TEAM=<team id> CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual build
```

Sign with a real Apple Development identity, not ad-hoc. An ad-hoc build's designated
requirement is its cdhash, so every rebuild silently loses Accessibility, Automation and
Microphone permissions (System Settings still shows the stale entry as enabled, but the
paste fails). With a stable identity, the permissions survive rebuilds. When switching
signature once, run `tccutil reset Accessibility com.local.dictate` (also `AppleEvents`,
`Microphone`) before launching so macOS prompts again.

After building, install only one app bundle:

```bash
RELEASE_APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/Dictate-*/Build/Products/Release/Dictate.app | head -n 1)
pkill -x Dictate || true
rm -rf /Applications/Dictate.app
ditto "$RELEASE_APP" /Applications/Dictate.app
find ~/Library/Developer/Xcode/DerivedData -path '*/Build/Products/Debug/Dictate.app' -prune -type d -exec rm -rf {} +
find ~/Library/Developer/Xcode/DerivedData -path '*/Build/Products/Release/Dictate.app' -prune -type d -exec rm -rf {} +
open /Applications/Dictate.app
```

Do not launch the app directly from `DerivedData`; that creates a second visible/running Dictate app next to `/Applications/Dictate.app`.

## Current Behavior

- Push-to-talk hotkey is configurable: Left Option or Fn. Hotkey handling works on press/release edges (`DictateApp.swift`).
- `KeyboardTap.swift` is a session event tap (needs Accessibility). It swallows Esc only while recording or transcribing (cancel) and Space while the hotkey is held during a recording (hands-free), and reports real key presses/clicks for smart spacing. Do not use double-tap Fn for anything: macOS binds it to Apple Dictation by default.
- Hands-free: hotkey + Space starts and ends it (a bare Fn tap opens the emoji picker on many Macs, so it does nothing in hands-free). Recordings stop after 10 minutes (`handsFreeLimit`). The tap is only enabled while a dictation runs (`setKeyCaptureActive`); "typed or clicked since last paste" comes from a passive NSEvent global monitor.
- Learning from corrections (`CorrectionLearner.swift`, pure and unit-testable; `FocusedText.swift` for AX access): after a paste the field is polled every 1.5 s for up to 180 s; the last non-empty snapshot (a window around the paste) is compared word-by-word with the pasted text. Only 1:1 (or 1:2 split/merge) replacements with similar spelling are learned, max 2 per dictation; a replacement where both old and new words are known to NSSpellChecker (de/en) is treated as a grammar edit and ignored. Learned terms are appended to the vocabulary and listed in `learned` in `~/.dictate-vocab.json`. Electron apps such as T3 Code report no system-wide focused element, so `FocusedText.element()` searches the focused window for the focused text field.
- ElevenLabs Live keyterms: the newest 50 terms (≤ 20 characters) are sent.
- Smart spacing (`needsLeadingSpace`): a leading space only when Accessibility shows a non-space character before the caret, or, for fields that hide their text, when nothing was typed or clicked in the same app since the last paste.
- Logging uses `appLog` (os.Logger, public messages; read with `/usr/bin/log show --predicate 'subsystem == "com.local.dictate"'`). Never log dictated text.
- The menu bar icon turns red only while `isRecording` is true.
- History and Vocabulary open as dedicated menu pages, not disclosure menus.
- Vocabulary terms are stored at `~/.dictate-vocab.json`.
- App settings are stored at `~/.dictate-config.json`.
- Transcription engine is selectable in the menu ("Engine"): Groq Whisper, ElevenLabs Scribe v2, or ElevenLabs Live (`provider` in the config: `groq` (default), `elevenlabs`, `elevenlabs_live`).
- ElevenLabs Live (`RealtimeTranscriber.swift`, `LivePreviewPanel.swift`): streams 16 kHz PCM to `wss://api.elevenlabs.io/v1/speech-to-text/realtime` (`scribe_v2_realtime`, manual commits). The realtime model drops uncommitted speech older than ~25 s, so the client commits in a pause (chunk RMS < 400) after 15 s and at the latest after 20 s; the final commit is padded to the server's 0.3 s minimum (else `commit_throttled`) and waits until every sent commit is answered. After an intermediate commit the server sometimes returned nothing for the rest of the stream (a 50 s hands-free test with microphone audio kept only the first 14 s; also seen with loud noise), so any dictation with an intermediate commit is re-transcribed via batch before pasting. A pause for a soft commit is 3 consecutive quiet 0.1 s chunks. On any stream failure the recorder's full buffer is transcribed via the batch Scribe endpoint and a warning is shown. Live partials go to `LivePreviewModel`, never to `@Published` state on `DictateManager` (menu pickers leak on every redraw on macOS 26). `endLiveTranscription()` runs on every exit path so no socket or panel outlives a dictation.
- API keys: `~/.groq-api-key` and `~/.elevenlabs-api-key` (or `GROQ_API_KEY` / `ELEVENLABS_API_KEY` env vars). Auto-Correct always uses Groq.
- Errors are never silent: `reportIssue` plays an error sound, turns the menu bar icon into a red (error) or orange (warning) triangle, shows the message at the top of the menu until dismissed or the next clean dictation, posts a notification if allowed, and logs via NSLog.
- If Auto-Correct fails, the raw transcription is still pasted and a warning is shown.
- Groq returns HTTP 403 "Access denied" for VPN/datacenter IPs (e.g. ProtonVPN); ElevenLabs works behind the VPN.
