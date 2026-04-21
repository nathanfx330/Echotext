# EchoText 

A clean, dark-themed Flutter desktop application for on-the-fly Text-to-Speech (TTS) using local [Piper](https://github.com/rhasspy/piper) neural models. 

EchoText runs completely offline, piping your text directly into the Piper engine and playing the generated audio instantly.

## ✨ New in this Version
* **Highly Accurate Subtitles (.SRT Export):** You can now generate `.srt` subtitle files alongside your `.wav` exports. EchoText mathematically calculates audio durations from the raw WAV headers and uses a custom **16-bit PCM Voice Activity Detector (VAD)** to strip trailing neural silence. This drastically reduces subtitle drift during massive (4-hour+) audio exports!
* **Native Desktop Editing Experience:**
  * **Right-Click to Read:** Right-click anywhere in the editor and select "🔊 Read from here" from the native context menu.
  * **Double-Click Start:** Double-click anywhere on the text to instantly start playing from that sentence.
  * **Interactive Playback:** Single-click on any highlighted sentence while audio is playing to instantly jump to that part of the text.
  * **Zero Layout Shifts:** A custom text highlighting controller ensures the scrollbar stays native and the UI never violently jumps when playback starts.
* **Advanced Magic Format Cleaner:** 
  * **PDF Line Fixer:** Automatically re-joins broken sentences copied from PDFs, with a custom minimum-character slider and "Smart-join" logic for transcript labels (e.g., "Q", "A", "Speaker:").
  * **AI Artifact Cleaner:** Instantly strips out Markdown artifacts (like `**bold**` and `### headers`).
  * **Unicode Stripper:** Safely removes emojis and non-standard symbols that commonly crash TTS engines.
* **Long-Form Generation Safety:** 
  * Massive audiobook exports now feature a real-time **ETA and Progress Bar**.
  * **Error Logging:** If a weird sentence crashes the Piper engine during a 4-hour export, the app catches it, skips it, finishes the audio, and generates an `echotext_audio_errors.log` file so you know exactly what was dropped.
* **Ctrl+F Search:** A native search bar that highlights matches in the text and auto-scrolls to them.
* **Undo Stack:** A 20-step undo memory protects you from accidental text clearing or massive Find & Replace mistakes.

## Features
* **100% Offline TTS:** Powered by local `.onnx` models. No cloud APIs or internet connection required.
* **Dynamic Model Selection:** Switch models on the fly via the dropdown, or load custom `.onnx` voice models using the built-in file picker.
* **Audio & Subtitle Export:** Save your generated speech directly to `.wav` files, with optional highly-accurate `.srt` files.
* **Advanced Playback Controls:** Adjust speech speed (length scale) and choose specific speakers for multi-speaker models.
* **Auto-Save:** Never lose your work. EchoText automatically saves your text and settings between sessions.
* **Folder-Based Voice Management:** Drop multiple Piper voices into sub-folders inside the `model` directory, and EchoText will automatically scan and populate them.
* **Cross-Platform:** Supports both Linux and Windows.
* **Clean Architecture:** Separated into distinct UI, Service, and Model layers for easy maintenance.

## Setup & Installation

### 1. Prerequisites
* [Flutter SDK](https://flutter.dev/docs/get-started/install) (v3.11.3 or higher)
* A compiled [Piper executable](https://github.com/rhasspy/piper/releases) for your OS.
* A Piper `.onnx` voice model and its accompanying `.onnx.json` config file.

### 2. Project Structure
To run EchoText locally, place the Piper executable and your models in the root of the project. You can now organize voices into folders:

```text
echotext/
├── model/
│   ├── Voice A/
│   │   ├── piper.onnx       
│   │   └── piper.onnx.json  
│   ├── Voice B/
│   │   ├── voice_b.onnx
│   │   └── voice_b.onnx.json
├── piper/
│   ├── piper            <-- The Piper executable (piper.exe on Windows)
│   └── espeak-ng-data/  <-- Required for Piper to process phonemes
├── lib/
│   ├── main.dart
│   ├── models/
│   ├── screens/
│   └── services/
├── linux/
├── windows/
└── pubspec.yaml
```
*(Note: The `model/` and `piper/` directories are ignored by Git to keep the repository lightweight and protect custom models).*

### 3. Run Locally
Ensure your Linux `piper` binary has execute permissions (the app attempts to do this automatically, but you can do it manually):
```bash
chmod +x piper/piper
```
Then run the app:
```bash
flutter run -d linux   # or windows
```

### 4. Build for Release
When building for release, the custom CMake configurations will automatically copy your `piper/` and `model/` folders into the final bundle alongside the executable.

```bash
# For Linux
flutter build linux

# For Windows
flutter build windows
```

## License
Distributed under the MIT License. 
MIT License

Copyright (c) 2026 Nathaniel Westveer

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.