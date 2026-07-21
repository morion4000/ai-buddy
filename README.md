# AI Buddy 🎙️

A tiny macOS menu-bar app for **push-to-talk dictation**. Press your hotkey,
speak, and Google **Gemini** transcribes your voice to text — then types it
wherever your cursor is and copies it to your clipboard.

- 🔘 **One global hotkey** — hold-to-talk *or* toggle, you choose. Default: hold **Right ⌥ (Option)**.
- 🧠 **Gemini speech-to-text** — uses any audio-capable Gemini model (default `gemini-3.5-flash`; one-click presets for `gemini-3.1-flash-lite`, `gemini-flash-latest`, etc.).
- ⌨️ **Types at your cursor** in any app, **and** keeps the text on the clipboard.
- 🔑 **Your own API key**, stored securely in the macOS Keychain.
- 🧹 **Optional filler-word cleanup** — strip "um", "uh", false starts, and stutters for tidier text.
- ⏯️ **Pauses whatever's playing** (YouTube, Spotify, Music…) while you record, then resumes it.
- 📸 **Region screenshots** — a second hotkey draws a capture area; shots float on the right edge as draggable thumbnails (drag into any app, click to copy, ✕ to dismiss).
- 💵 **Usage & cost estimate** — counts real tokens per request and prices them from a built-in per-model table.
- 📋 **Local transcription history** (up to 1,000, with a clear-history control), launch-at-login, custom transcription prompt.
- 🧩 **Conversation keywords** — locally extracted topics from saved transcriptions provide soft context for future dictation, separately from the exact-spelling custom dictionary.

> Lives only in the menu bar (no Dock icon). ~900 lines of Swift, no
> dependencies, builds from the command line in a couple of seconds.

---

## Build & run

Requires Xcode 26 / Swift 6.3 on macOS 26 (Apple Silicon).

```bash
./build.sh
open "build/AI Buddy.app"
```

That's it. A 🎙️ mic icon appears in your menu bar.

## Building a release DMG

To package the app into a distributable disk image, run:

```bash
./make-dmg.sh
```

This builds the app (via `build.sh`), then produces **`build/AI Buddy.dmg`** — the
`.app` plus an `/Applications` symlink, so users just drag AI Buddy onto
Applications to install. If a *Developer ID Application* identity is in your
keychain, both the app and the DMG are signed with it automatically.

| Variable | Effect |
|---|---|
| `SKIP_BUILD=1` | Reuse the existing `build/AI Buddy.app` instead of rebuilding. |
| `NOTARIZE=1` | Submit the DMG to Apple's notary service and staple the ticket. |
| `RELEASE=1` | Publish the DMG + appcast to the auto-update feed, tag `v<version>`, and create a GitHub release (requires `NOTARIZE=1`). |
| `RELEASE_NOTES` | Optional release notes shown in the in-app update prompt. |
| `NOTARY_PROFILE` | notarytool credential profile to use (default `AI Buddy`). |
| `SIGN_IDENTITY` | Force a specific signing identity. |

### Auto-updates

The app updates itself from a JSON appcast at
`https://updates.claudete.co/ai-buddy/appcast.json` (the same public R2 bucket
Claudete's updater uses). Once a day (and via **Check for Updates…** in the menu) the app
compares the feed's version against its own; when a newer one exists it offers
to install, then downloads the DMG, verifies the new app is signed by the same
Developer ID team, swaps the bundle in place, and relaunches.

To ship an update: bump `CFBundleShortVersionString` in `Info.plist`, commit,
then run:

```bash
NOTARIZE=1 RELEASE=1 ./make-dmg.sh
```

This uploads `AI-Buddy-<version>.dmg` and a refreshed `appcast.json` to the
bucket (credentials from `.env.notarize`, falling back to
`../claudete/.env.notarize`). Optionally set `RELEASE_NOTES="…"` to show notes
in the update prompt.

Unsigned/dev builds refuse to auto-install updates (there's no team identity to
verify against) and point at the download page instead.

### Notarizing for distribution

A signed-but-unnotarized DMG still triggers a Gatekeeper warning ("Apple could
not verify…") on other Macs. To ship without warnings, notarize it. Store an
[app-specific password](https://support.apple.com/102654) once:

```bash
xcrun notarytool store-credentials "AI Buddy" \
  --apple-id you@example.com --team-id YOURTEAMID
```

Then build and notarize in one step:

```bash
NOTARIZE=1 ./make-dmg.sh
```

The script uploads the DMG, waits for Apple's verdict, and staples the ticket so
the image passes Gatekeeper offline.

## First-time setup

The Settings window opens automatically on first launch. You'll need to:

1. **Paste your Gemini API key.** Get a free one at
   [aistudio.google.com/apikey](https://aistudio.google.com/apikey).
2. **Grant three permissions** (buttons in the *Permissions* section open the
   right System Settings pane):
   | Permission | Why | 
   |---|---|
   | **Microphone** | to record your voice |
   | **Input Monitoring** | so the global hotkey works anywhere |
   | **Accessibility** | to type the text into other apps |
3. **Quit and reopen the app** after enabling Input Monitoring / Accessibility
   (macOS only applies those once the app restarts).

## Using it

- **Hold-to-talk mode** (default): hold your hotkey, speak, release. The text
  appears at your cursor.
- **Toggle mode**: press once to start listening, press again to stop.
- **Press Esc while recording to discard** the take without transcribing (also
  available as *Cancel* in the menu).
- Change the hotkey anytime in **Settings ▸ Trigger** — click the shortcut
  button and press any key, combo, or a single modifier like Right ⌥.
- You can also start/stop from the menu-bar icon, and pick any recent
  transcription from the **Recent Transcriptions** submenu to re-insert it at
  the cursor (and copy it).
- The latest 1,000 transcription texts are saved locally so AI Buddy can extract
  conversation keywords. Clear them anytime in **Settings ▸ Advanced**; temporary
  audio files are deleted after each transcription.

The menu-bar icon reflects state: `mic` (idle) → `mic.fill` red + a running
`m:ss` timer (listening) → `waveform` (transcribing).

A **max recording length** (Settings ▸ Advanced, default 60s) auto-stops a take
as a safety net, so a missed key-release can't record — and bill — forever.
**Test connection** (Settings ▸ Gemini) checks your key and model in one click.

## Choosing a model

Any Gemini model that accepts audio input works. Pick from **Settings ▸ Gemini ▸
Presets**, or type a model id directly:

| Model | Notes |
|---|---|
| `gemini-3.5-flash` | **Default.** Fast and accurate for transcription. |
| `gemini-2.5-flash` | Previous default. Closed to new API keys — existing users are migrated off it automatically. |
| `gemini-3.1-flash-lite` | Cheapest; tuned for ASR / high volume. |
| `gemini-3-flash-preview` | Preview of the Gemini 3 base Flash. |
| `gemini-flash-latest` | Alias that tracks the latest Flash release. |

> Note: "Gemini 3.1 Flash TTS" is the *text-to-speech* (audio-out) model — not
> what we want here. For dictation (audio-*in* → text) use one of the models above.

Transcription is sent to the stable `generateContent` endpoint with your audio
inlined as `audio/mp4` (16 kHz mono AAC, 32 kbps) — roughly 8× smaller than the
PCM WAV this used to send, so the upload stops padding the pause between
releasing the key and seeing text. Gemini bills audio by duration rather than
bytes, so the smaller file costs exactly the same. Audio never touches any
server but Google's.

## Keeping permissions across rebuilds

With the default **ad-hoc** signature, macOS identifies the app by a hash that
changes every build, so it may ask you to re-grant Microphone / Input Monitoring
/ Accessibility after each `./build.sh`. To make grants stick:

1. In **Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…**,
   make a *Code Signing* certificate (e.g. named `AI Buddy Dev`).
2. Build with it:
   ```bash
   SIGN_IDENTITY="AI Buddy Dev" ./build.sh
   ```
   Now TCC keys the permissions to the stable signing identity, and they survive
   rebuilds. (If you ever change identities, run
   `tccutil reset All com.morion4000.gemini-dictation` to clear stale grants.)

## How it works

| File | Responsibility |
|---|---|
| `main.swift` | App entry point (menu-bar agent bootstrap). |
| `AppDelegate.swift` | Wires the menu, hotkey, recorder, Gemini, and text injection together. |
| `HotkeyEngine.swift` | Global hotkey via a listen-only `CGEventTap` (supports hold *and* toggle, including bare-modifier triggers). |
| `Recorder.swift` | Records the mic to a 16 kHz mono WAV via `AVAudioRecorder`. |
| `GeminiClient.swift` | Calls the Gemini `generateContent` API for transcription. |
| `TextInjector.swift` | Pastes (clipboard-preserving) or types text at the cursor. |
| `AppState.swift` / `Keychain.swift` | Settings (UserDefaults) + API key (Keychain). |
| `SettingsView.swift` / `ShortcutRecorderView.swift` | SwiftUI settings UI. |
| `Permissions.swift` / `KeyDisplay.swift` / `Util.swift` | TCC helpers, shortcut rendering, sounds & notifications. |

## Troubleshooting

- **Hotkey does nothing** → Input Monitoring isn't granted, *or* you didn't
  restart the app after granting it. Check the Permissions section.
- **"Microphone access needed"** → grant Microphone, then try again.
- **Text is copied but not typed** → grant Accessibility. Some apps block
  synthetic paste; enable *"Type characters instead of pasting"* in Settings.
- **`Gemini API error 400/404`** → check the model id, or that your key has the
  Gemini API enabled. `429` means you've hit a rate limit.
- **No text came back** → likely no intelligible speech was detected.

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md):
you're welcome to read, build, and modify AI Buddy for personal, noncommercial
use, but commercial use and redistribution aren't permitted. For the ready-made
signed, notarized, auto-updating build, see
[claudete.co/ai-buddy](https://claudete.co/ai-buddy).
