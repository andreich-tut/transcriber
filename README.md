# Transcriber

A macOS app for transcribing audio on your Mac with downloadable Whisper models, or through an OpenAI-compatible server or API. Choose a file, get its transcript, and save the result as TXT and JSON. If the server returns timestamped segments, the app displays them alongside the text.

## Requirements

- macOS 13.3 or later (Apple Silicon or Intel).
- Swift 5.9 or later and Xcode command-line tools to build the app.
- Python 3 from the Xcode command-line tools for the package verification script.
- For local recognition: internet access for the initial model download and enough disk space for the selected model.
- For Server or External API: an accessible OpenAI-compatible endpoint with `POST /v1/audio/transcriptions` and a JSON response containing a `text` field.

The app uses SwiftUI, AppKit, AVFoundation, and URLSession, with the official whisper.cpp 1.8.3 macOS framework for local recognition. Swift Package Manager downloads and verifies the pinned framework during the first build. The build script includes it in the application bundle; no separate model runner, server, or package manager is needed at runtime. See `THIRD-PARTY-NOTICES.md` for licenses.

## Build and launch

```sh
./scripts/build-app.sh
```

The built app is available at `dist/Transcriber.app`. Open it in Finder or move it into your Applications folder. The build uses a local ad-hoc signature and includes the English and Russian localization resources.

The build uses only public dependencies, an isolated SwiftPM configuration, and a minimal environment. SwiftPM Keychain and `.netrc` authentication are disabled. Signing explicitly uses `--sign -` and requires no Apple Developer account or signing credentials. The completed app and bundled framework are checked for ad-hoc signatures without a team identity. A clean staging directory prevents leftover files from entering the app; the package check also rejects developer home paths, obsolete branding, and credential files. Run it again with `python3 scripts/verify-app.py dist/Transcriber.app`.

## Usage

1. Open **Settings…** and choose **On this Mac**, **Server**, or **External API**. For local recognition, download the selected model first.
2. Click **Choose audio file…**. Local recognition accepts formats supported by AVFoundation, including audio tracks in video containers; server support depends on the selected endpoint.
3. Click **Transcribe**. A timer and cancellation control are available during processing.
4. Review the text and any timestamps included in the response.
5. Click **Save TXT and JSON…** and choose a folder.
6. Click **Show in Finder** to reveal the exported files.

Results remain in memory until saved. Choosing another file triggers a warning if the current result has not been saved. If export filenames already exist, the app finds an available pair by adding `-1`, `-2`, and so on.

## Settings

Open **Settings…** or press `⌘,`. The labels below use the English interface.

### Appearance

Choose **System**, **Light**, or **Dark**. The system theme follows macOS settings. Changes apply immediately and persist across app restarts.

### Interface language

Choose **System language**, **Русский**, or **English**. The default is **System language**: the app uses Russian when the preferred macOS language is Russian, including regional variants, and English otherwise.

Changes apply immediately to app labels, processing status, and app-generated error messages, and persist across restarts. Clicking **Cancel** in Settings does not undo theme or interface language changes. Standard macOS dialog controls and system-generated error details follow macOS localization; messages returned by the server are preserved.

The interface language is independent of the transcription language. Switching the interface does not change the language sent to the server or translate existing transcripts.

### Processing mode and model selection

The settings form has three modes. Each mode preserves its own model, transcription language, and timeout. Server and External API also have separate addresses and Keychain entries, so switching to another mode keeps the previous connection intact.

**On this Mac** runs Whisper inside the app. A fresh installation selects **Whisper Base**. Earlier connection settings within the current app identity are migrated to **Server** and keep their address, model, language, format, and timeout.

| Local model | Download size | Intended use |
|---|---:|---|
| Whisper Tiny | 78 MB | Smallest download and quick checks. |
| Whisper Base | 148 MB | Default local model. |
| Whisper Small | 488 MB | Higher accuracy with more memory and processing time. |
| Whisper Large v3 Turbo | 1.62 GB | Higher accuracy; needs more memory. |

All four are multilingual, including Russian and English. Use **Download model** to download the selected weights, watch progress, or cancel. The app verifies the published file size and SHA-256 checksum before installation. Incomplete downloads are never listed as ready. **Remove model** deletes the selected downloaded model, and **Show in Finder** reveals it.

Models are stored in `~/Library/Application Support/Transcriber/Models`. Downloads are independent of the settings form: closing or cancelling Settings keeps completed models and allows an active download to continue. Transcription on this Mac is available once its selected model is downloaded. Audio stays on the device, and later transcription needs no internet connection. Local results include timestamps.

**Server** connects to an OpenAI-compatible server on localhost or a remote computer. It defaults to a loopback address and the Nemotron model name. Choose **Nemotron 3.5**, **Whisper**, or **Custom model**; a custom choice exposes a model-name field. The server manages and installs its own models.

**External API** has its own connection profile, initially `https://api.openai.com/v1` with `whisper-1`. Choose Whisper or enter a custom model name for the configured provider. This mode sends the audio to the configured address.

| Connection setting | Purpose |
|---|---|
| Base URL | Address such as `http://127.0.0.1:18000/v1` or a remote HTTPS URL. The app adds `/audio/transcriptions` automatically. |
| Model | A predetermined model choice, or a custom server model name. |
| Transcription language | `ru`, `en`, or another supported code. Leave blank for automatic detection. |
| API key | Optional Bearer token, stored separately for Server and External API in macOS Keychain. |
| Response format | `json` for text, or `verbose_json` for servers that support timestamps. |
| Timeout, minutes | Maximum processing time, from 1 to 1440 minutes; also available for local recognition. |

**Save** validates the selected mode and applies the settings to the next transcription. **Cancel** discards profile edits. Settings are unavailable during processing. If a server needs an SSH tunnel, configure it separately.

## Processing and export

For Server and External API, the multipart request includes `model`, `response_format`, and `file`, plus `language` when it is nonempty. If an API key is configured, the app adds an `Authorization: Bearer …` header.

The multipart body is assembled in a temporary file, reading audio in 1 MB chunks. The temporary file is removed after success, failure, or cancellation. Allow enough free disk space for roughly one additional copy of the audio. Cancelling the client request does not guarantee that server-side computation stops.

Local decoding uses AVFoundation to produce mono 16 kHz floating-point audio for whisper.cpp. The decoded samples are held in memory (about 230 MB per hour of audio, in addition to model memory). Cancellation and the configured timeout apply during decoding and inference. Unsupported formats and language codes produce an actionable error.

TXT contains UTF-8 text. JSON preserves every server response field with readable formatting. The `text` field is required; `segments` is optional. Segment timestamps in `segments[].start/end` are expressed in seconds.

Processing settings and connection profiles, excluding API keys, the theme, and the interface language are stored in macOS preferences. The bundle ID is `local.transcriber`; API keys use the `local.transcriber.connection` Keychain service. Settings and API keys from installations with a previous app identity are not imported: enter them again after upgrading. Existing downloaded models remain available.

## Checks

```sh
swift test
```

Tests also cover profile migration and isolation, predetermined model choices, download integrity, and missing local models. Native integration is opt-in: set `TRANSCRIBER_TEST_MODEL_DIR` to a model cache directory and `TRANSCRIBER_TEST_AUDIO` to a synthetic English recording containing “local transcription”. It downloads Tiny if necessary, verifies recognition and timestamps, and cancels a subsequent inference.

Tests start a local HTTP server on an available loopback port and use synthetic data. They cover multipart requests, connection settings, authorization, server responses, errors, timeouts, cancellation, and export. Localization checks cover system language selection, persistence, complete translation catalogs, matching format placeholders, and error translation after a language change. The test server uses `/usr/bin/python3`.

The distributed app contains no recordings, transcripts, saved user settings, or API keys. Test fixtures contain synthetic data. Transcription preserves the content of the selected recording; it does not automatically remove personal information from speech or exported text.

Real recordings, transcripts, local reports, configurations containing secrets, and build outputs are excluded from Git. For manual end-to-end checks, use a suitable anonymized recording and save results outside the repository.

## Localization resources

English and Russian strings live in `Sources/TranscriberCore/Resources/en.lproj/Localizable.strings` and `Sources/TranscriberCore/Resources/ru.lproj/Localizable.strings`. Keep keys and format placeholders consistent across both files. English source strings serve as lookup keys and fallback text. Code comments and documentation are written in English.

## Icon

Source: `assets/AppIcon.png`. The icon shows an audio waveform flowing into lines of text. ICNS is generated during the build using the standard `sips` and `iconutil` tools. See `assets/icon-prompt.md` for the description and generation prompt.
