import 'dart:async';
import 'dart:io';
import 'dart:convert'; // Added for JSON Batch Mode
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/voice_model.dart';

class PiperService {
  final AudioPlayer audioPlayer = AudioPlayer();
  final Set<Process> _activeProcesses = {}; 
  
  late String exePath;
  late String modelsBaseDir;
  
  List<VoiceModel> availableVoices = [];
  
  bool isInitialized = false;
  int _currentPlaybackId = 0; 
  Completer<void>? _playCompleter;

  PiperService() {
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
          if ((name.startsWith('chunk_') || name.startsWith('export_chunk_') || name.startsWith('temp_raw_audio') || name.startsWith('test_gpu')) && 
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
              availableVoices.add(VoiceModel(name: p.basename(entity.path), path: f.path));
              break;
            }
          }
        }
      }
    }
    availableVoices.sort((a, b) => a.name.compareTo(b.name));
  }

  Future<bool> testGpuSupport(String modelPath) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final outFile = p.join(tempDir.path, 'test_gpu_${DateTime.now().millisecondsSinceEpoch}.wav');
      final f = File(outFile);

      Process process = await Process.start(exePath, ['--model', modelPath, '--output_file', outFile, '--cuda']);
      
      // Capture the ENTIRE stderr stream as a Future so we don't miss the error
      Future<String> stderrFuture = process.stderr.transform(utf8.decoder).join();
      
      process.stdout.drain();
      
      process.stdin.write("Test.");
      await process.stdin.close();
      
      final exitCode = await process.exitCode;
      
      // Await the full string here to guarantee we read the C++ logs
      String stderrOutput = await stderrFuture; 
      
      if (await f.exists()) await f.delete();

      String lowerData = stderrOutput.toLowerCase();
      
      // Look for any ONNX Runtime CUDA complaints
      if (lowerData.contains('failed') || 
          lowerData.contains('warning') || 
          lowerData.contains('not available') || 
          lowerData.contains('error')) {
        return false;
      }
      
      if (exitCode == 0) return true;
      
      return false;
    } catch (e) {
      print("GPU Test Error: $e");
      return false;
    }
  }

  Future<void> playChunks(
    List<String> chunks, {
    required String modelPath,
    required double speed,
    required int speakerId,
    required bool useGpu,
    required Function(int) onChunkStart,
    int startIndex = 0,
  }) async {
    _currentPlaybackId++;
    final int myPlaybackId = _currentPlaybackId;
    final tempDir = await getTemporaryDirectory();
    Future<String?>? nextGenFuture;

    for (int i = startIndex; i < chunks.length; i++) {
      if (myPlaybackId != _currentPlaybackId) break;

      String? currentFile = (i == startIndex || nextGenFuture == null)
          ? await _generateChunk(chunks[i], i, tempDir.path, modelPath, speed, speakerId, useGpu, myPlaybackId)
          : await nextGenFuture;

      if (myPlaybackId != _currentPlaybackId) break;

      if (i + 1 < chunks.length) {
        nextGenFuture = _generateChunk(chunks[i + 1], i + 1, tempDir.path, modelPath, speed, speakerId, useGpu, myPlaybackId);
      }

      if (currentFile != null && myPlaybackId == _currentPlaybackId) {
        onChunkStart(i); 
        _playCompleter = Completer<void>();
        
        try {
          await audioPlayer.play(DeviceFileSource(currentFile));
          await _playCompleter!.future; 
        } catch (e) {
          print("AudioPlayback Error on chunk $i: $e");
          if (_playCompleter != null && !_playCompleter!.isCompleted) _playCompleter!.complete();
        }
      }
    }
  }

  Future<String?> _generateChunk(String text, int index, String dir, String modelPath, double speed, int speakerId, bool useGpu, int playbackId) async {
    if (!text.contains(RegExp(r'[a-zA-Z0-9\p{L}]', unicode: true))) return null;
    if (playbackId != _currentPlaybackId) return null;
    
    final outFile = p.join(dir, 'chunk_${index}_$playbackId.wav');
    final f = File(outFile);

    try {
      List<String> args = ['--model', modelPath, '--output_file', outFile, '--length_scale', speed.toStringAsFixed(2)];
      if (speakerId > 0) args.addAll(['--speaker', speakerId.toString()]);
      if (useGpu) args.add('--cuda');

      Process process = await Process.start(exePath, args);
      _activeProcesses.add(process);
      
      process.stdout.drain();
      process.stderr.drain();
      process.stdin.write(text);
      await process.stdin.close();
      
      final exitCode = await process.exitCode;
      _activeProcesses.remove(process);

      if (playbackId != _currentPlaybackId) return null;
      if (exitCode == 0 && await f.exists() && await f.length() > 100) return outFile;
    } catch (e) {
      print("Error generating playback chunk $index: $e");
    }
    return null;
  }

  // --- AUDIO & SRT EXPORT LOGIC ---

  String _formatSrtTime(int totalMilliseconds) {
    int hours = totalMilliseconds ~/ 3600000;
    int minutes = (totalMilliseconds % 3600000) ~/ 60000;
    int seconds = (totalMilliseconds % 60000) ~/ 1000;
    int milliseconds = totalMilliseconds % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')},${milliseconds.toString().padLeft(3, '0')}';
  }

  String _formatETA(int totalMilliseconds) {
    if (totalMilliseconds < 0) return "00:00";
    int totalSeconds = totalMilliseconds ~/ 1000;
    int hours = totalSeconds ~/ 3600;
    int minutes = (totalSeconds % 3600) ~/ 60;
    int seconds = totalSeconds % 60;
    if (hours > 0) return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  int _findChunk(Uint8List b, String chunkId) {
    if (b.length < 12) return -1;
    int offset = 12;
    while (offset + 8 <= b.length) {
      String id = String.fromCharCodes(b.sublist(offset, offset + 4));
      int size = ByteData.view(b.buffer).getUint32(offset + 4, Endian.little);
      if (id == chunkId) return offset;
      offset += 8 + size; 
    }
    return -1;
  }

  Future<bool> generateToFile(
    String text,
    String outputPath, {
    required String modelPath,
    required double speed,
    required int speakerId,
    required bool useGpu,
    List<String>? exportChunks, 
    bool isSubtitlesRequested = false, 
    void Function(int current, int total, String eta)? onProgress,
  }) async {
    
    // FAST MONOLITHIC FALLBACK (No Subtitles)
    if (exportChunks == null || exportChunks.isEmpty) {
      try {
        List<String> args = ['--model', modelPath, '--output_file', outputPath, '--length_scale', speed.toStringAsFixed(2)];
        if (speakerId > 0) args.addAll(['--speaker', speakerId.toString()]);
        if (useGpu) args.add('--cuda');

        Process process = await Process.start(exePath, args);
        _activeProcesses.add(process);
        
        process.stdout.drain();
        process.stderr.drain();
        process.stdin.write(text);
        await process.stdin.close();

        final exitCode = await process.exitCode;
        _activeProcesses.remove(process);
        return exitCode == 0;
      } catch (e) {
        print("Error generating fast file: $e");
        return false;
      }
    }

    // --- PIPER JSON BATCH MODE (Massive Speedup for Chunks & SRT) ---
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    
    List<String> args = ['--model', modelPath, '--json-input', '--length_scale', speed.toStringAsFixed(2)];
    if (speakerId > 0) args.addAll(['--speaker', speakerId.toString()]);
    if (useGpu) args.add('--cuda');

    Process process = await Process.start(exePath, args);
    _activeProcesses.add(process);
    
    process.stdout.drain(); // Piper echoes json to stdout, we don't need it.

    int completedCount = 0;
    int totalCount = exportChunks.length;
    DateTime startTime = DateTime.now();

    // Listen to stderr for Piper's "Real-time factor" to track progress live
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.contains('Real-time factor') || line.contains('Failed to synthesize')) {
        completedCount++;
        if (onProgress != null) {
          int elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
          double msPerChunk = elapsedMs / (completedCount > 0 ? completedCount : 1);
          int remainingMs = (msPerChunk * (totalCount - completedCount)).toInt();
          onProgress(completedCount, totalCount, _formatETA(remainingMs));
        }
      }
    });

    List<String> tempWavPaths = [];

    // Push all chunks into Piper's pipeline via JSON immediately
    for (int i = 0; i < totalCount; i++) {
      String tempWavPath = p.join(tempDir.path, 'export_chunk_${timestamp}_$i.wav');
      tempWavPaths.add(tempWavPath);
      
      Map<String, String> payload = {
        "text": exportChunks[i],
        "output_file": tempWavPath
      };
      
      // Feed Piper the JSON line
      process.stdin.writeln(jsonEncode(payload));
    }

    // Tell Piper we are done sending text
    await process.stdin.flush();
    await process.stdin.close();

    // Wait for Piper to finish generating all the files
    await process.exitCode;
    _activeProcesses.remove(process);

    // --- STITCHING & VAD PHASE (Super fast RAM math) ---
    int srtIndex = 1;
    StringBuffer srtContent = StringBuffer();
    StringBuffer errorLog = StringBuffer(); 
    
    File rawAudioTempFile = File(p.join(tempDir.path, 'temp_raw_audio_$timestamp.tmp'));
    var rawSink = rawAudioTempFile.openWrite();
    
    int totalDataBytes = 0;
    int? sampleRate, numChannels, bitsPerSample, byteRate, blockAlign;

    for (int i = 0; i < totalCount; i++) {
      File chunkFile = File(tempWavPaths[i]);
      String textChunk = exportChunks[i];

      if (await chunkFile.exists() && await chunkFile.length() >= 44) {
        var bytes = await chunkFile.readAsBytes();
        int fmtOffset = _findChunk(bytes, 'fmt ');
        int dataOffset = _findChunk(bytes, 'data');
        
        if (fmtOffset != -1 && dataOffset != -1) {
          ByteData view = ByteData.view(bytes.buffer);
          if (sampleRate == null) {
            numChannels = view.getUint16(fmtOffset + 10, Endian.little);
            sampleRate = view.getUint32(fmtOffset + 12, Endian.little);
            byteRate = view.getUint32(fmtOffset + 16, Endian.little);
            blockAlign = view.getUint16(fmtOffset + 20, Endian.little);
            bitsPerSample = view.getUint16(fmtOffset + 22, Endian.little);
          }
          
          int dataSize = view.getUint32(dataOffset + 4, Endian.little);
          int actualAvailable = bytes.length - (dataOffset + 8);
          int readSize = (dataSize < actualAvailable && dataSize > 0) ? dataSize : actualAvailable;
          readSize = readSize - (readSize % blockAlign!);
          
          if (readSize > 0) {
            Uint8List audioData = bytes.sublist(dataOffset + 8, dataOffset + 8 + readSize);
            
            // PCM VAD Stripper
            if (bitsPerSample == 16 && audioData.length >= blockAlign!) {
              ByteData chunkView = ByteData.view(audioData.buffer, audioData.offsetInBytes, audioData.length);
              int threshold = 150, firstAudible = 0;
              for (int j = 0; j <= audioData.length - blockAlign!; j += blockAlign!) {
                if (chunkView.getInt16(j, Endian.little).abs() > threshold) { firstAudible = j; break; }
              }
              
              int lastAudible = audioData.length - blockAlign!;
              if (lastAudible < 0) lastAudible = 0;
              for (int j = audioData.length - blockAlign!; j >= firstAudible; j -= blockAlign!) {
                if (chunkView.getInt16(j, Endian.little).abs() > threshold) { lastAudible = j; break; }
              }
              
              int padBytes = (byteRate! * 0.05).toInt();
              padBytes = padBytes - (padBytes % blockAlign!); 
              firstAudible = (firstAudible - padBytes).clamp(0, audioData.length);
              lastAudible = (lastAudible + padBytes).clamp(0, audioData.length - blockAlign!);
              
              if (lastAudible >= firstAudible) {
                audioData = audioData.sublist(firstAudible, lastAudible + blockAlign!);
                int minBytes = (byteRate! * 0.05).toInt(); 
                minBytes = minBytes - (minBytes % blockAlign!); 
                if (audioData.length < minBytes) audioData = Uint8List(0); 
              } else {
                audioData = Uint8List(0); 
              }
            }

            if (audioData.isNotEmpty) {
              int startBytes = totalDataBytes; 
              rawSink.add(audioData);
              totalDataBytes += audioData.length;
              
              int startMs = (startBytes * 1000) ~/ byteRate!;
              int endMs = (totalDataBytes * 1000) ~/ byteRate!;
              int displayEndMs = endMs - 15; 
              if (displayEndMs <= startMs) displayEndMs = startMs + 10;
              
              String safeText = textChunk.trim().replaceAll(RegExp(r'\s+'), ' ');
              srtContent.writeln(srtIndex++);
              srtContent.writeln('${_formatSrtTime(startMs)} --> ${_formatSrtTime(displayEndMs)}');
              srtContent.writeln(safeText);
              srtContent.writeln(); 
            } else {
              errorLog.writeln('CHUNK $i FAILED: VAD removed all audio. TEXT: $textChunk\n');
            }
          } else {
            errorLog.writeln('CHUNK $i FAILED: WAV valid but 0 bytes. TEXT: $textChunk\n');
          }
        } else {
          errorLog.writeln('CHUNK $i FAILED: No fmt/data chunks. TEXT: $textChunk\n');
        }
        await chunkFile.delete(); 
      } else {
        errorLog.writeln('CHUNK $i FAILED: Piper failed to generate chunk. TEXT: $textChunk\n');
      }
    }
    
    await rawSink.flush();
    await rawSink.close();
    
    // FINAL MASTER FILE GENERATION
    if (sampleRate != null && totalDataBytes > 0) {
       File finalWavFile = File(outputPath);
       var finalSink = finalWavFile.openWrite();
       
       var header = ByteData(44);
       header.setUint8(0, 0x52); header.setUint8(1, 0x49); header.setUint8(2, 0x46); header.setUint8(3, 0x46); 
       header.setUint32(4, totalDataBytes + 36, Endian.little);
       header.setUint8(8, 0x57); header.setUint8(9, 0x41); header.setUint8(10, 0x56); header.setUint8(11, 0x45); 
       header.setUint8(12, 0x66); header.setUint8(13, 0x6D); header.setUint8(14, 0x74); header.setUint8(15, 0x20); 
       header.setUint32(16, 16, Endian.little);
       header.setUint16(20, 1, Endian.little);
       header.setUint16(22, numChannels!, Endian.little);
       header.setUint32(24, sampleRate!, Endian.little);
       header.setUint32(28, byteRate!, Endian.little);
       header.setUint16(32, blockAlign!, Endian.little);
       header.setUint16(34, bitsPerSample!, Endian.little);
       header.setUint8(36, 0x64); header.setUint8(37, 0x61); header.setUint8(38, 0x74); header.setUint8(39, 0x61); 
       header.setUint32(40, totalDataBytes, Endian.little);
       
       finalSink.add(header.buffer.asUint8List());
       await finalSink.addStream(rawAudioTempFile.openRead());
       await finalSink.flush();
       await finalSink.close();
       
       if (isSubtitlesRequested) {
         String srtPath = outputPath.replaceAll(RegExp(r'\.wav$', caseSensitive: false), '.srt');
         if (srtPath == outputPath) srtPath += '.srt'; 
         await File(srtPath).writeAsString(srtContent.toString());
       }
       
       if (errorLog.isNotEmpty) {
         String logPath = outputPath.replaceAll(RegExp(r'\.wav$', caseSensitive: false), '_errors.log');
         if (logPath == outputPath) logPath += '_errors.log';
         await File(logPath).writeAsString("ECHO TEXT GENERATION ERRORS\n===========================\n\n${errorLog.toString()}");
       }
    }
    
    if (await rawAudioTempFile.exists()) await rawAudioTempFile.delete();
    
    return totalDataBytes > 0;
  }

  Future<void> stop() async {
    _currentPlaybackId++; 
    for (var p in _activeProcesses) {
      p.kill(); 
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