import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/voice_model.dart';

class PiperService {
  final AudioPlayer audioPlayer = AudioPlayer();
  final Set<Process> _activeProcesses = {}; // Tracks multiple processes to kill them cleanly
  
  late String exePath;
  late String modelsBaseDir;
  
  List<VoiceModel> availableVoices = [];
  
  bool isInitialized = false;
  int _currentPlaybackId = 0; // Unique ID to prevent ghost loops from playing
  Completer<void>? _playCompleter;

  PiperService() {
    // Listen for when a sentence finishes playing successfully
    audioPlayer.onPlayerComplete.listen((_) {
      if (_playCompleter != null && !_playCompleter!.isCompleted) {
        _playCompleter!.complete();
      }
    });
  }

  Future<void> init() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final currentDir = Directory.current.path;
    final exeName = Platform.isWindows ? 'piper.exe' : 'piper';

    String potentialPiperProd = p.join(exeDir, 'piper', exeName);
    String potentialPiperDev = p.join(currentDir, 'piper', exeName);

    if (File(potentialPiperProd).existsSync()) {
      exePath = potentialPiperProd;
      modelsBaseDir = p.join(exeDir, 'model');
    } else {
      exePath = potentialPiperDev;
      modelsBaseDir = p.join(currentDir, 'model');
    }

    await scanForVoices();

    if (!Platform.isWindows && File(exePath).existsSync()) {
      await Process.run('chmod', ['+x', exePath]);
    }
    
    // Clear out old temp files from previous sessions
    _clearTempAudio();

    isInitialized = true;
  }
  
  Future<void> _clearTempAudio() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final files = tempDir.listSync();
      for (var file in files) {
        if (file is File && p.basename(file.path).startsWith('chunk_') && file.path.endsWith('.wav')) {
          try { file.deleteSync(); } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> scanForVoices() async {
    availableVoices.clear();
    final dir = Directory(modelsBaseDir);
    
    if (await dir.exists()) {
      final entities = await dir.list().toList();
      for (var entity in entities) {
        if (entity is Directory) {
          final files = await entity.list().toList();
          for (var f in files) {
            if (f is File && f.path.toLowerCase().endsWith('.onnx')) {
              availableVoices.add(VoiceModel(
                name: p.basename(entity.path),
                path: f.path,
              ));
              break;
            }
          }
        }
      }
    }
    availableVoices.sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> playChunks(
    List<String> chunks, {
    required String modelPath,
    required double speed,
    required int speakerId,
    required Function(int) onChunkStart,
    int startIndex = 0,
  }) async {
    // Generate a new unique playback ID for this run
    _currentPlaybackId++;
    final int myPlaybackId = _currentPlaybackId;
    
    final tempDir = await getTemporaryDirectory();
    Future<String?>? nextGenFuture;

    for (int i = startIndex; i < chunks.length; i++) {
      // Abort if the user jumped/stopped (ID changed)
      if (myPlaybackId != _currentPlaybackId) break;

      // Await current audio generation (either direct or from the background future)
      String? currentFile = (i == startIndex || nextGenFuture == null)
          ? await _generateChunk(chunks[i], i, tempDir.path, modelPath, speed, speakerId, myPlaybackId)
          : await nextGenFuture;

      if (myPlaybackId != _currentPlaybackId) break;

      // Start generating the NEXT chunk in the background while we prepare to play THIS chunk
      if (i + 1 < chunks.length) {
        nextGenFuture = _generateChunk(chunks[i + 1], i + 1, tempDir.path, modelPath, speed, speakerId, myPlaybackId);
      }

      if (currentFile != null && myPlaybackId == _currentPlaybackId) {
        onChunkStart(i); // Notify the UI to move the highlight
        
        _playCompleter = Completer<void>();
        
        try {
          await audioPlayer.play(DeviceFileSource(currentFile));
          await _playCompleter!.future; // Wait until playback finishes
        } catch (e) {
          // If GStreamer/audio system crashes on a specific file, skip it and keep going safely
          print("AudioPlayback Error on chunk $i: $e");
          if (_playCompleter != null && !_playCompleter!.isCompleted) {
            _playCompleter!.complete();
          }
        }
      }
    }
  }

  // Helper to generate a single chunk's audio file
  Future<String?> _generateChunk(String text, int index, String dir, String modelPath, double speed, int speakerId, int playbackId) async {
    // SECURITY CHECK: If the text doesn't contain any real letters or numbers, Piper will generate 
    // a 0-second file that crashes audio players. Skip it instantly.
    if (!text.contains(RegExp(r'[a-zA-Z0-9\p{L}]', unicode: true))) {
      return null;
    }
    if (playbackId != _currentPlaybackId) return null;
    
    // Use a unique file name tied to this specific playback run to avoid file lock/deletion crashes
    final outFile = p.join(dir, 'chunk_${index}_$playbackId.wav');
    final f = File(outFile);

    List<String> args = [
      '--model', modelPath,
      '--output_file', outFile,
      '--length_scale', speed.toStringAsFixed(2),
    ];
    if (speakerId > 0) args.addAll(['--speaker', speakerId.toString()]);

    Process process = await Process.start(exePath, args);
    _activeProcesses.add(process);
    
    process.stdin.write(text);
    await process.stdin.close();
    
    final exitCode = await process.exitCode;
    _activeProcesses.remove(process);

    if (playbackId != _currentPlaybackId) return null;

    // SECURITY CHECK 2: Ensure file was created AND is larger than a basic 44-byte WAV header
    if (exitCode == 0 && await f.exists() && await f.length() > 100) {
      return outFile;
    }
    return null;
  }

  Future<bool> generateToFile(
    String text,
    String outputPath, {
    required String modelPath,
    required double speed,
    required int speakerId,
  }) async {
    List<String> args = [
      '--model', modelPath,
      '--output_file', outputPath,
      '--length_scale', speed.toStringAsFixed(2),
    ];
    if (speakerId > 0) args.addAll(['--speaker', speakerId.toString()]);

    Process process = await Process.start(exePath, args);
    _activeProcesses.add(process);
    
    process.stdin.write(text);
    await process.stdin.close();

    final exitCode = await process.exitCode;
    _activeProcesses.remove(process);
    
    return exitCode == 0;
  }

  Future<void> stop() async {
    _currentPlaybackId++; // Instantly invalidate all loops/futures
    
    for (var p in _activeProcesses) {
      p.kill(); // Kill all running Piper generators
    }
    _activeProcesses.clear();
    
    await audioPlayer.stop();
    
    if (_playCompleter != null && !_playCompleter!.isCompleted) {
      _playCompleter!.complete();
    }
  }

  void dispose() {
    stop();
    audioPlayer.dispose();
  }
}