# sttapp

System-wide speech-to-text desktop app built with Flutter and rust pluggins. (Currently only tested in Fedora)

sttapp records audio, transcribes it with an OpenAI-compatible API, copies the transcript to the clipboard, and can paste it into the active application. The app supports global shortcuts, tray controls, and local settings storage.

Recommendation to use Groq's `Whisper 3 large turbo` for the best experience.

## Pre-built Binaries
Take a look [here](https://github.com/lmtr0/sttapp/releases)

## Building from source

- Flutter stable
- Dart SDK from Flutter
- Rust stable
- Platform desktop build tools:
  - Linux: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `libayatana-appindicator3-dev`, `libkeybinder-3.0-dev`, `libasound2-dev`, `cargo`
  - macOS: Xcode command line tools
  - Windows: Visual Studio C++ build tools
- Linux runtime secret storage requires an available and unlocked Secret Service provider such as GNOME Keyring or KWallet.

## Development

Install dependencies:

```bash
flutter pub get
```

Run the desktop app:

```bash
flutter run -d linux
flutter run -d macos
flutter run -d windows
```

Build a release:

```bash
flutter build linux --release
flutter build macos --release
flutter build windows --release
```

## Project Layout

- `lib/` contains the Flutter app.
- `packages/sttapp_audio/` contains the native audio and FLAC package.
- `packages/sttapp_input/` contains native input and paste helpers.
- - `packages/sttapp_secret_store/` contains native secret store implementation helpers.
- `linux/`, `macos/`, and `windows/` contain desktop platform runners.
- `.github/workflows/` contains CI and release publishing workflows.
