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

- Push-to-talk hotkey is configurable: Left Option or Fn.
- The menu bar icon turns red only while `isRecording` is true.
- History and Vocabulary open as dedicated menu pages, not disclosure menus.
- Vocabulary terms are stored at `~/.dictate-vocab.json`.
- App settings are stored at `~/.dictate-config.json`.
- Transcription engine is selectable in the menu ("Engine"): Groq Whisper or ElevenLabs Scribe v2 (`provider` in the config, default `groq`).
- API keys: `~/.groq-api-key` and `~/.elevenlabs-api-key` (or `GROQ_API_KEY` / `ELEVENLABS_API_KEY` env vars). Auto-Correct always uses Groq.
- Errors are never silent: `reportIssue` plays an error sound, turns the menu bar icon into a red (error) or orange (warning) triangle, shows the message at the top of the menu until dismissed or the next clean dictation, posts a notification if allowed, and logs via NSLog.
- If Auto-Correct fails, the raw transcription is still pasted and a warning is shown.
- Groq returns HTTP 403 "Access denied" for VPN/datacenter IPs (e.g. ProtonVPN); ElevenLabs works behind the VPN.
