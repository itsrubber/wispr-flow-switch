# wispr-flow-switch

Minimal macOS menu bar prototype for Wispr Flow dictation.

It now has two modes:

- `Wispr Flow API`: captures microphone audio with AVFoundation, streams short 16 kHz mono 16-bit PCM WAV/base64 chunks to the Wispr Flow WebSocket API, commits on Off, then pastes final returned text into the active app with the clipboard plus `cmd-v`.
- `Hotkey Fallback`: preserves the original bridge behavior by sending the configured global Wispr Flow hotkey with public `CGEvent` APIs.

The default fallback hotkey is:

```text
command+option+control+space
```

## API Access Caveat

Wispr Flow API access is currently exclusive access. You need an API key from:

```text
https://platform.wisprflow.ai
```

This prototype uses the documented WebSocket endpoint:

```text
wss://platform-api.wisprflow.ai/api/v1/dash/ws?api_key=Bearer%20<API_KEY>
```

Audio sent to the API is single-channel 16-bit signed integer PCM WAV at 16 kHz, base64 encoded. The WebSocket flow sends `auth`, `append`, and `commit` messages and handles `auth`, `info`, `text`, and `error` statuses.

## Security Warning

The API key is stored in local `UserDefaults` for prototype convenience. That is not encrypted secret storage. Use a test or limited key, and move this to Keychain before treating the app as production software.

## Requirements

- macOS 13 or newer
- Xcode command line tools or Xcode
- Microphone permission for API mode
- Accessibility permission for pasting final API text and for hotkey fallback
- Wispr Flow hotkey configured only if you use `Hotkey Fallback`

## Build

```sh
make app
```

The app bundle is written to:

```text
dist/Wispr Flow Switch.app
```

Run it with:

```sh
make run
```

For a plain SwiftPM build:

```sh
swift build
```

## Usage

Open the app from the menu bar.

1. Choose `Mode: Wispr Flow API` or `Mode: Hotkey Fallback`.
2. In API mode, choose `Set API Key...` and paste the key from `https://platform.wisprflow.ai`.
3. Switch `Dictation` to `On` to start microphone capture or trigger the fallback hotkey.
4. Switch `Dictation` to `Off` to commit API audio or trigger the fallback hotkey again.

In API mode, final text responses are pasted into the currently active app. Keep the target text field focused before switching Off.

Use `Configure Hotkey...` from the menu to change the fallback shortcut. The format is plus-separated, for example:

```text
command+option+control+space
shift+control+d
```

Supported modifiers are `command`, `option`, `control`, and `shift`.

You can also configure the fallback hotkey with `defaults`:

```sh
defaults write dev.local.wispr-flow-switch HotKey "command+option+control+space"
```

## Permissions

macOS requires Microphone permission for API mode.

macOS also requires Accessibility permission for apps that synthesize keyboard input for other apps. This is needed for final-text paste in API mode and for the hotkey fallback mode.

On first launch, macOS should prompt for permission. If it does not, open:

```text
System Settings > Privacy & Security
```

Then enable the app under `Microphone` and `Accessibility`. If you run from SwiftPM during development, the permission may apply to the built executable path under `.build` instead of the app bundle.

## Prototype Notes

The API client is intentionally small and uses public `URLSessionWebSocketTask` and AVFoundation APIs only. It queues audio packets until an `auth` status arrives, sends append messages with `audio_packets.packets`, `volumes`, `packet_duration`, `audio_encoding`, `byte_encoding`, and `position`, and sends `commit` with `total_packets` when dictation is switched Off.

The response parser only pastes text marked final by common final flags such as `final`, `is_final`, or `complete`. If the API uses a different final-text marker, adjust `WisprFlowAPIClient.handle(_:)`.

## CI

GitHub Actions runs `swift build` on `macos-latest` for a syntax and build check.
