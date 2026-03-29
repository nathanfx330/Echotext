# EchoText 

A clean, dark-themed Flutter desktop application for on-the-fly Text-to-Speech (TTS) using local [Piper](https://github.com/rhasspy/piper) neural models. 

EchoText runs completely offline, piping your text directly into the Piper engine and playing the generated audio instantly.

## Features
* **100% Offline TTS:** Powered by local `.onnx` models. No cloud APIs or internet connection required.
* **Cross-Platform:** Supports both Linux and Windows.
* **Automatic Bundling:** CMake configurations automatically bundle your local Piper executable and models into the final release build.
* **Clean UI:** A distraction-free, modern dark theme built with Material 3.

## Setup & Installation

### 1. Prerequisites
* [Flutter SDK](https://flutter.dev/docs/get-started/install) (v3.11.3 or higher)
* A compiled [Piper executable](https://github.com/rhasspy/piper/releases) for your OS.
* A Piper `.onnx` voice model and its accompanying `.onnx.json` config file.

### 2. Project Structure
To run EchoText locally, you need to place the Piper executable and your models in the root of the project:

```text
echotext/
├── model/
│   ├── piper.onnx       <-- Your downloaded/trained voice model
│   └── piper.onnx.json  <-- The config for the model
├── piper/
│   ├── piper            <-- The Piper executable (piper.exe on Windows)
│   └── espeak-ng-data/  <-- Required for Piper to process phonemes
├── lib/
├── linux/
├── windows/
└── pubspec.yaml
```
*(Note: The `model/` and `piper/` directories are ignored by Git to keep the repository lightweight and protect custom models).*

### 3. Run Locally
Ensure your Linux `piper` binary has execute permissions (the app will attempt to do this automatically, but you can do it manually):
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
Distributed under the MIT License. See `LICENSE` for more information.