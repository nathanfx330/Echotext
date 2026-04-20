import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
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
        if (file is File) {
          String name = p.basename(file.path);
          if ((name.startsWith('chunk_') || name.startsWith('export_chunk_') || name.startsWith('temp_raw_audio')) && 
             (name.endsWith('.wav') || name.endsWith('.tmp'))) {
            try { file.deleteSync(); } catch (_) {}
          }
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

  Future<String?> _generateChunk(String text, int index, String dir, String modelPath, double speed, int speakerId, int playbackId) async {
    if (!text.contains(RegExp(r'[a-zA-Z0-9\p{L}]', unicode: true))) {
      return null;
    }
    if (playbackId != _currentPlaybackId) return null;
    
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

    if (exitCode == 0 && await f.exists() && await f.length() > 100) {
      return outFile;
    }
    return null;
  }

  // Helper function to format milliseconds to SRT timestamp format (HH:MM:SS,MMM)
  String _formatSrtTime(int totalMilliseconds) {
    int hours = totalMilliseconds ~/ 3600000;
    int minutes = (totalMilliseconds % 3600000) ~/ 60000;
    int seconds = (totalMilliseconds % 60000) ~/ 1000;
    int milliseconds = totalMilliseconds % 1000;

    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')},${milliseconds.toString().padLeft(3, '0')}';
  }

  Future<bool> generateToFile(
    String text,
    String outputPath, {
    required String modelPath,
    required double speed,
    required int speakerId,
    List<String>? chunksForSubtitles, // If provided, generates a matching .srt file
  }) async {
    // Standard fast generation if no subtitles are requested
    if (chunksForSubtitles == null || chunksForSubtitles.isEmpty) {
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

    // --- CHUNK & STITCH GENERATION (For perfect Subtitle Timings) ---
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    
    int srtIndex = 1;
    int currentOffsetMs = 0;
    StringBuffer srtContent = StringBuffer();
    
    // We stream the raw audio bytes here temporarily so we don't hold it all in memory
    File rawAudioTempFile = File(p.join(tempDir.path, 'temp_raw_audio_$timestamp.tmp'));
    var rawSink = rawAudioTempFile.openWrite();
    
    int totalDataBytes = 0;
    Uint8List? referenceHeaderBytes;
    
    for (int i = 0; i < chunksForSubtitles.length; i++) {
      String textChunk = chunksForSubtitles[i];
      // Skip empty or non-spoken chunks
      if (!textChunk.contains(RegExp(r'[a-zA-Z0-9\p{L}]', unicode: true))) continue;

      String tempWavPath = p.join(tempDir.path, 'export_chunk_${timestamp}_$i.wav');
      File chunkFile = File(tempWavPath);

      List<String> args = [
        '--model', modelPath,
        '--output_file', tempWavPath,
        '--length_scale', speed.toStringAsFixed(2),
      ];
      if (speakerId > 0) args.addAll(['--speaker', speakerId.toString()]);

      Process process = await Process.start(exePath, args);
      _activeProcesses.add(process);
      process.stdin.write(textChunk);
      await process.stdin.close();
      await process.exitCode;
      _activeProcesses.remove(process);

      if (await chunkFile.exists() && await chunkFile.length() > 44) {
         var bytes = await chunkFile.readAsBytes();
         
         // Grab the exact 44-byte WAV header generated by this specific Piper model
         if (referenceHeaderBytes == null) {
            referenceHeaderBytes = Uint8List.fromList(bytes.sublist(0, 44));
         }
         
         Uint8List headerChunk = Uint8List.fromList(bytes.sublist(0, 44));
         ByteData headerData = ByteData.view(headerChunk.buffer);
         
         int byteRate = headerData.getUint32(28, Endian.little);
         int dataSize = headerData.getUint32(40, Endian.little);
         
         // Safely handle if dataSize in header isn't perfect
         int actualDataSize = bytes.length - 44;
         int readSize = (dataSize < actualDataSize && dataSize > 0) ? dataSize : actualDataSize;

         Uint8List audioData = bytes.sublist(44, 44 + readSize);
         rawSink.add(audioData);
         totalDataBytes += audioData.length;
         
         // Math: Duration = (Total Bytes * 1000) / Bytes Per Second
         int durationMs = (audioData.length * 1000) ~/ byteRate;
         
         int startMs = currentOffsetMs;
         int endMs = currentOffsetMs + durationMs;
         
         srtContent.writeln(srtIndex++);
         srtContent.writeln('${_formatSrtTime(startMs)} --> ${_formatSrtTime(endMs)}');
         srtContent.writeln(textChunk.trim());
         srtContent.writeln(); // Blank line between subtitles
         
         currentOffsetMs = endMs;
         await chunkFile.delete(); // Cleanup to save space
      }
    }
    
    await rawSink.flush();
    await rawSink.close();
    
    if (referenceHeaderBytes != null && totalDataBytes > 0) {
       // Re-write the master header with the massive stitched file lengths
       ByteData modifiedHeader = ByteData.view(referenceHeaderBytes.buffer);
       modifiedHeader.setUint32(4, totalDataBytes + 36, Endian.little); // File Size - 8
       modifiedHeader.setUint32(40, totalDataBytes, Endian.little);      // Pure Data Size
       
       File finalWavFile = File(outputPath);
       var finalSink = finalWavFile.openWrite();
       
       // Write Header
       finalSink.add(referenceHeaderBytes);
       
       // Stream in the raw audio data
       await finalSink.addStream(rawAudioTempFile.openRead());
       await finalSink.flush();
       await finalSink.close();
       
       // Write the SRT text file side-by-side with the WAV file
       String srtPath = outputPath.replaceAll(RegExp(r'\.wav$', caseSensitive: false), '.srt');
       if (srtPath == outputPath) srtPath += '.srt'; // Fallback if extension was missing
       await File(srtPath).writeAsString(srtContent.toString());
    }
    
    if (await rawAudioTempFile.exists()) {
       await rawAudioTempFile.delete();
    }
    
    return totalDataBytes > 0;
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