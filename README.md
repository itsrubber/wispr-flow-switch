# wispr-flow-switch

Minimal macOS menu bar app that toggles Wispr Flow hands-free dictation by sending a global hotkey.

The default hotkey is:

```text
command+option+control+space
```

The app does not use private APIs or talk to Wispr Flow directly. It only posts the configured keyboard shortcut with public `CGEvent` APIs.

## Requirements

- macOS 13 or newer
- Xcode command line tools or Xcode
- Wispr Flow configured to use the same hands-free dictation hotkey

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

Open the app and use the menu bar item to switch hands-free dictation on or off. Each switch action sends the configured global hotkey, so the app keeps only a local desired state indicator. If Wispr Flow is toggled elsewhere, use the switch once to bring the local indicator back in sync.

Use `Configure Hotkey...` from the menu to change the shortcut. The format is plus-separated, for example:

```text
command+option+control+space
shift+control+d
```

Supported modifiers are `command`, `option`, `control`, and `shift`.

You can also configure it with `defaults`:

```sh
defaults write dev.local.wispr-flow-switch HotKey "command+option+control+space"
```

## Permissions

macOS requires Accessibility permission for apps that synthesize keyboard input for other apps.

On first launch, macOS should prompt for permission. If it does not, open:

```text
System Settings > Privacy & Security > Accessibility
```

Then enable `Wispr Flow Switch`. If you run from SwiftPM during development, the permission may apply to the built executable path under `.build` instead of the app bundle.

## CI

GitHub Actions runs `swift build` on `macos-latest` for a syntax and build check.
