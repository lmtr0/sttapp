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

Released builds embed tags in the form
`v<year>.<major>.<mmdd>.<unix-seconds>`. To exercise the update UI without a
published release, provide both the current and fake latest tags in a debug
build:

```bash
flutter run -d linux \
  --dart-define=STTAPP_RELEASE_TAG=v2026.1.0713.1783900800 \
  --dart-define=STTAPP_FAKE_LATEST_TAG=v2026.1.0713.1783904400
```

The fake tag is ignored in release builds. Give both defines the same value to
test the “latest version” status; open Settings from the tray because an
up-to-date app remains hidden at startup. Replace `linux` with `macos` or
`windows` to test another desktop target.

Build a release:

```bash
flutter build linux --release
flutter build macos --release
flutter build windows --release
```

## Installing on Windows

Download and run `sttapp-windows-x64-<version>-setup.exe`. The installer copies
the complete application bundle and installs the required Microsoft Visual C++
Redistributable. Administrator approval is required because both are installed
for all users under Program Files.

If the app does not open, its early native and Dart startup diagnostics are in
`%LOCALAPPDATA%\sttapp\startup.log`. Installer diagnostics can be captured by
running the setup executable with `/LOG="sttapp-installer.log"`.

## Troubleshooting global shortcuts

The app verifies both global shortcuts whenever it starts. If registration
fails, it retries after two seconds and then after another four seconds. If the
third attempt fails, the settings window stays open with the failed combination
and a **Retry registration** action. Release the shortcut in the other
application, or select another function key on macOS and Windows, then retry.
Registration attempts and shortcut activation events are written to the startup
log (`%LOCALAPPDATA%\sttapp\startup.log` on Windows and
`$TMPDIR/sttapp/startup.log` on Linux and macOS).

## Installing on macOS

macOS releases are distributed as a single universal DMG that runs natively on
both Intel and Apple Silicon Macs. Open the DMG and drag `sttapp.app` into the
Applications folder.

The current DMG is not Developer ID signed or notarized. On first launch,
Control-click `sttapp.app` in Finder, choose **Open**, and confirm that you want
to run it. On macOS versions that do not offer that confirmation immediately,
attempt to open the app once and then use **System Settings > Privacy & Security
> Open Anyway**.

sttapp needs both of these permissions before capture is enabled:

- **Microphone** records audio only after you start a transcription.
- **Accessibility** sends the paste shortcut to the application that was active
  when transcription started.

The first-run setup window explains and requests both permissions. If access is
denied or later revoked, open **System Settings > Privacy & Security**, select
**Microphone** or **Accessibility**, enable sttapp, and return to the app. The
status refreshes when the setup window regains focus.

Because the app is unsigned, replacing it with a new downloaded build may cause
macOS to request approval or privacy permissions again. A Developer ID signing
and notarization step can be added to the release workflow later without
changing the universal build or DMG layout.

## Project Layout

- `lib/` contains the Flutter app.
- `packages/sttapp_audio/` contains the native audio and FLAC package.
- `packages/sttapp_input/` contains native input and paste helpers.
- - `packages/sttapp_secret_store/` contains native secret store implementation helpers.
- `linux/`, `macos/`, and `windows/` contain desktop platform runners.
- `.github/workflows/` contains CI and release publishing workflows.
