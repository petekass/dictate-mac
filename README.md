# Dictate

Native macOS menu bar app for push-to-talk voice dictation. Hold **Option (⌥)** anywhere, speak, release — the transcribed text is pasted at the cursor.

- Transcribes with **Groq's `whisper-large-v3-turbo`** (free tier, very fast) or **ElevenLabs Scribe v2**, selectable in the menu
- **ElevenLabs Live** engine streams audio while you speak, shows the text live in a small overlay and pastes it right after release
- Optional LLM post-correction with custom vocabulary (`qwen/qwen3.8-27b` on Groq)
- **Native Swift app** — no Terminal, no Python, no dependencies
- Lives in the macOS menu bar — no Dock icon, no window
- Works in any app (Slack, Mail, browser, editor…)

## Why

Paid alternatives: Wispr Flow ($), SuperWhisper ($), MacWhisper ($).
This is free, open source, and runs on Groq's free tier — which is generous enough for daily use (2000 requests/day, 8 hours of audio/day).

## Requirements

- macOS 14.0+ (Sonoma or newer)
- Apple Silicon or Intel Mac
- A free [Groq API key](https://console.groq.com/keys) and/or an [ElevenLabs API key](https://elevenlabs.io/app/settings/api-keys) with Speech to Text access

## Install

### Option 1: Download Release
1. Download `Dictate-vX.Y.zip` from the [Releases](https://github.com/peterflowset/dictate-mac/releases) page and unzip it.
2. Move `Dictate.app` to `/Applications`.
3. **First launch:** right-click `Dictate.app` → **Open** → confirm. The app is not signed with an Apple Developer ID, so Gatekeeper blocks the normal double-click on first launch. Only required once.

### Option 2: Build from Source
```bash
git clone https://github.com/peterflowset/dictate-mac.git
cd dictate-mac/Dictate
xcodebuild -project Dictate.xcodeproj -scheme Dictate -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/Dictate-*/Build/Products/Release/Dictate.app /Applications/
```

## Setup

1. **Launch** `/Applications/Dictate.app`
2. **Grant Accessibility permission** when prompted (System Settings → Privacy & Security → Accessibility → enable Dictate)
3. **Set your API key**: Click the menu bar icon → pick the Engine → "Set" next to the key → paste the key for that engine
4. **Grant Microphone permission** when prompted on first recording

## Usage

- **Hold left Option (⌥)** → speak → release → text is pasted at the cursor
- **Hands-free:** while holding the hotkey, tap **Space**; recording continues after you let go. Press the hotkey again to finish (stops by itself after 10 minutes)
- **Esc** cancels a dictation while recording or transcribing; nothing is pasted and the Esc key does not reach the app
- Consecutive dictations are separated by a space when the text before the cursor needs one
- Click the menu bar icon for settings:
  - **History** — opens a dedicated view with recent transcriptions; click any entry to copy it
  - **Vocabulary** — opens a dedicated view for custom recognition terms
  - **Auto-Correct** — LLM post-processing to fix mis-hearings and remove filler words
  - **Save to Clipboard** — keep transcribed text in clipboard instead of restoring previous content
  - **Engine** — Groq Whisper, ElevenLabs Scribe, or ElevenLabs Live (streaming with live preview)
  - **Language** — Auto / German / English
  - **Hotkey** — choose Left Option or Fn for push-to-talk

### Menu Bar Icons

| Icon | State |
|------|-------|
| `〰` | Idle — ready to record |
| `◉` | Recording — speak now; menu bar icon turns red |
| `…` | Processing — transcribing |
| `⚠` red | Error — open the menu to see what failed (also plays a low falling tone) |
| `⚠` orange | Warning — e.g. Auto-Correct skipped, raw text was pasted |

Errors stay visible at the top of the menu until you dismiss them or the next dictation succeeds. If Groq answers `HTTP 403 Access denied`, it is blocking your IP (common with VPNs); switch the Engine to ElevenLabs or pause the VPN.

### ElevenLabs Live

With the **ElevenLabs Live** engine, audio is streamed to ElevenLabs Scribe v2 Realtime over a WebSocket while you hold the hotkey. A small panel at the bottom of the screen under the mouse shows the text as it is recognised (grey words may still change). On release only the last segment is committed, so the final text arrives about 0.2 s later (measured) instead of after a full upload, and is pasted right away.

- Uses the same ElevenLabs API key as ElevenLabs Scribe. Streamed audio is billed by ElevenLabs, including pauses.
- Dictations up to about 15 seconds are pasted straight from the stream. For longer ones the stream has to be committed in between (the realtime model forgets speech older than about 25 seconds), and after such a commit it sometimes stopped returning text. So the pasted text of a long dictation comes from the normal transcription of the full recording, which takes about a second longer; the preview stays live.
- If the stream fails, the full recording is transcribed the normal way and a warning is shown, so nothing is lost.
- The panel never takes focus, so the paste still goes to the app you are typing in.
- Vocabulary terms longer than 20 characters are not sent to the realtime API (its limit); at most 50 terms are used.

### Learning from corrections

When you fix a misheard word right after a dictation (for example "Osbifo" → "Ospivo"), Dictate adds the corrected spelling to the vocabulary, marked with ✦. It watches the field it pasted into for up to three minutes (chat fields until you send) and only learns a single word replaced by a similarly spelled one, at most two per dictation. Rewritten sentences, deleted or added text, and words the macOS spell checker already knows teach nothing. The field text is compared in memory and never stored or logged. Turn it off with **Learn from Corrections** in the menu.

This needs the app to expose its text field through Accessibility: native fields and T3 Code do; some apps may not.

### Vocabulary

Add custom terms (names, technical words, company names) for better recognition:
1. Click menu bar icon → Vocabulary
2. Add a term with the input field and plus button, remove terms from the grid, or use "Edit All..."
3. Terms are used as Whisper context and for Auto-Correct

Saved at `~/.dictate-vocab.json`.

### Config

Settings saved at `~/.dictate-config.json`:
```json
{ "correct": false, "language": null, "save_to_clipboard": false, "hotkey": "left_option", "provider": "groq" }
```

API keys saved at `~/.groq-api-key` and `~/.elevenlabs-api-key`. Auto-Correct always runs through Groq.

## Troubleshooting

### Text not pasting
1. Enable **Accessibility** permission for Dictate.app
2. Enable **Automation** permission for System Events (System Settings → Privacy & Security → Automation → Dictate → System Events)

### "API Key missing"
Click the menu bar icon → "Set" → enter your Groq API key.

### "Hold Option longer"
Recording was under 0.3s. Hold Option longer while speaking.

### Menu bar icon doesn't appear
Your menu bar is probably full. Use [Bartender](https://www.macbartender.com/) or [Ice](https://github.com/jordanbaird/Ice) to manage overflow.

## Free-tier limits (Groq)

| Model | Per minute | Per day |
|---|---|---|
| whisper-large-v3-turbo | 20 req | 2000 req / 8 hours of audio |
| llama-3.3-70b-versatile (Auto-Correct) | 30 req | 1000 req / 100k tokens |

More than enough for normal dictation use.

## Building

Open `Dictate/Dictate.xcodeproj` in Xcode and build. Requires Xcode 15+.

## Uninstall

```bash
# Remove app
rm -rf /Applications/Dictate.app

# Remove config files (optional)
rm ~/.dictate-config.json ~/.dictate-vocab.json ~/.groq-api-key
```

## License

MIT — see [LICENSE](LICENSE).

## Credits

- [Groq](https://groq.com/) — fast free inference
