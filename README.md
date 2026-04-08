# EchoText 

A clean, dark-themed Flutter desktop application for on-the-fly Text-to-Speech (TTS) using local [Piper](https://github.com/rhasspy/piper) neural models. 

EchoText runs completely offline, piping your text directly into the Piper engine and playing the generated audio instantly.

## ✨ New in this Version
* **Bouncing Ball Highlighting:** Text is highlighted sentence-by-sentence as it is spoken, ensuring you never lose your place.
* **Interactive Playback:** 
  * Click on any sentence while audio is playing to instantly jump to that part of the text.
  * Put your text cursor anywhere in the editor and hit "Read Text" to start reading exactly from that spot.
  * Hit "Stop", and your text cursor will automatically snap to the exact sentence you stopped at so you can resume editing seamlessly.
* **AI Formatting Cleaner:** A built-in "Magic Wand" tool instantly strips out LLM/Markdown artifacts (like `**bold**`, `### headers`, and `_italics_`) so Piper reads natural text, not punctuation. Includes a standard Find & Replace.
* **Folder-Based Voice Management:** Drop multiple Piper voices into sub-folders inside the `model` directory, and EchoText will automatically scan and populate them in a dropdown menu.

## Features
* **100% Offline TTS:** Powered by local `.onnx` models. No cloud APIs or internet connection required.
* **Dynamic Model Selection:** Switch models on the fly via the dropdown, or load custom `.onnx` voice models using the built-in file picker.
* **Audio Export:** Save your generated speech directly to `.wav` files.
* **Advanced Playback Controls:** Adjust speech speed (length scale) and choose specific speakers for multi-speaker models.
* **Auto-Save:** Never lose your work. EchoText automatically saves your text and settings between sessions.
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