# sttapp

System-wide Speech-to-Text Desktop Application

A fast, lightweight desktop app that transcribes speech to text using OpenAI-compatible APIs. Features global hotkey support, automatic clipboard copying, and seamless paste-to-active-window functionality.

## Installation

### Pre-built Binaries

Download the latest release for your platform from [GitHub Releases](https://github.com/lmtr0/sttapp/releases):

- **Windows**: `.msi` or `.exe` installer
- **macOS**: `.dmg` or `.app`
- **Linux**: `.AppImage`, `.deb`, or `.rpm`

### Build from Source

#### Prerequisites

- [Rust](https://rustup.rs/) (latest stable)
- [Deno](https://deno.land/) runtime

#### Build Steps

```bash
git clone https://github.com/lmtr0/sttapp.git
cd sttapp
deno task build
deno task tauri build
```

Binaries will be available in `src-tauri/target/release/bundle/`.

## Configuration

### First-Time Setup

On first launch, the settings window opens automatically. Configure your API credentials to get started.

### API Configuration

The app requires an OpenAI-compatible API:

- **API Key**: Your API key (e.g., `sk-...` for OpenAI)
- **Base URL**: API endpoint (default: `https://api.openai.com/v1`)
- **Model**: Speech recognition model

### Preset Models

- `whisper-1` - OpenAI Whisper
- `whisper-large-v3` - Groq Whisper v3
- `whisper-large-v3-turbo` - Groq Whisper v3 Turbo

Custom models can be configured for other OpenAI-compatible APIs.

### Environment Variables

Alternatively, configure via environment variables:

```bash
export OPENAI_API_KEY="sk-your-key-here"
export OPENAI_BASE_URL="https://api.openai.com/v1"  # optional
export OPENAI_MODEL="whisper-1"  # optional
```

### Supported Providers

- [OpenAI](https://platform.openai.com/) - Default, uses `whisper-1`
- [Groq](https://console.groq.com/) - Fast inference, uses `whisper-large-v3` variants
- Any OpenAI-compatible API (custom base URL)

### Test Connection

Use the "Test Connection" button in settings to verify your API credentials before saving.

## Usage

### Quick Start

1. Launch sttapp
2. Configure API settings
3. Press **F8** to start recording
4. Press **F8** to stop and transcribe
5. Transcript auto-copies to clipboard and pastes into active window

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| **F8** | Start/stop recording, normal paste |
| **Shift+F8** | Start/stop recording, paste as plain text |

### System Tray

Right-click the tray icon to access:

- **Start Recording** - Begin audio capture
- **Stop Recording** - End capture and transcribe
- **Settings** - Open configuration window
- **Quit** - Exit application

The tray icon changes state during recording.

### Workflow

1. Press **F8** (or use tray menu) to start recording
2. Speak into your microphone
3. Press **F8** again to stop
4. Audio is encoded to FLAC and sent to the API
5. Transcript is copied to clipboard
6. Transcript is automatically pasted into the active window
7. Main window auto-hides (if not focused)

### Window Behavior

- Positioned at bottom-center of screen
- Auto-hides after successful transcription
- Can be closed at any time without affecting recording

## Development

### Prerequisites

- [Rust](https://rustup.rs/) (latest stable)
- [Deno](https://deno.land/) runtime
- Platform-specific build tools:
  - **Windows**: Microsoft Visual Studio C++ Build Tools
  - **macOS**: Xcode Command Line Tools (`xcode-select --install`)
  - **Linux**: `build-essential`, `libgtk-3-dev`, `libwebkit2gtk-4.0-dev`

### Development Commands

```bash
# Start frontend dev server
deno task dev

# Run Tauri in dev mode with hot reload
deno task tauri dev

# Type check
deno task check

# Build frontend
deno task build

# Build production binaries
deno task tauri build
```

### Project Structure

```
sttapp/
├── src/                    # SvelteKit frontend
│   ├── routes/            # SvelteKit routes
│   │   ├── +page.svelte   # Main recording window
│   │   └── settings/      # Settings page
│   └── lib/               # Shared utilities
│       └── config.ts      # Configuration management
├── src-tauri/             # Rust backend
│   ├── src/
│   │   ├── main.rs        # Entry point
│   │   └── lib.rs         # Core app logic
│   └── tauri.conf.json    # Tauri configuration
└── static/                # Static assets
    └── audio-processor.worklet.js  # Audio capture worklet
```

### Key Components

- **Audio Capture**: Uses AudioWorklet for efficient 16kHz mono capture
- **FLAC Encoding**: Client-side encoding via libflac.js
- **API Integration**: OpenAI-compatible transcription endpoint
- **Global Shortcuts**: F8 and Shift+F8 via Tauri global-shortcut plugin
- **Auto-paste**: Uses enigo for cross-platform keyboard simulation

### Platform Notes

- **Linux/Wayland**: Microphone permission handled programmatically for WebKitGTK
- **Linux/X11**: Requires `DISPLAY` environment variable
- **Windows**: No console window in release builds

## Contributing

Contributions are welcome! Here's how to get started:

### Development Workflow

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Test thoroughly using `deno task tauri dev`
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

### Code Style

- **Frontend**: TypeScript with Svelte 5 runes (`$state`, `$derived`)
- **Backend**: Rust with standard Rust formatting
- **Commits**: Clear, descriptive commit messages

### Reporting Issues

Report bugs or request features via [GitHub Issues](https://github.com/lmtr0/sttapp/issues).

Please include:

- Operating system and version
- Steps to reproduce
- Expected vs actual behavior
- Screenshots (if applicable)

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
