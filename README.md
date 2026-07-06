# sttapp

System-wide speech-to-text desktop app built with Flutter.

sttapp records audio, transcribes it with an OpenAI-compatible API, copies the transcript to the clipboard, and can paste it into the active application. The app supports global shortcuts, tray controls, and local settings storage.

## Requirements

- Flutter stable
- Dart SDK from Flutter
- Rust stable
- Platform desktop build tools:
  - Linux: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `libayatana-appindicator3-dev`, `libkeybinder-3.0-dev`, `libsecret-1-dev`, `libasound2-dev`
  - macOS: Xcode command line tools
  - Windows: Visual Studio C++ build tools

## Development

Install dependencies:

```bash
flutter pub get
```

Run checks:

```bash
flutter analyze
flutter test
(cd packages/sttapp_audio && dart test)
(cd packages/sttapp_input && dart test)
cargo test --locked --manifest-path packages/sttapp_audio/rust/Cargo.toml
cargo test --locked --manifest-path packages/sttapp_input/rust/Cargo.toml
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
- `linux/`, `macos/`, and `windows/` contain desktop platform runners.
- `.github/workflows/` contains CI and release publishing workflows.
