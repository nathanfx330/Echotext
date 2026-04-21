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
    StringBuffer srtContent = StringBuffer();
    
    // We stream the raw audio bytes here temporarily so we don't hold it all in memory
    File rawAudioTempFile = File(p.join(tempDir.path, 'temp_raw_audio_$timestamp.tmp'));
    var rawSink = rawAudioTempFile.openWrite();
    
    int totalDataBytes = 0;
    
    // Extracted directly from the chunks so the master header is perfectly accurate
    int? sampleRate;
    int? numChannels;
    int? bitsPerSample;
    int? byteRate;
    int? blockAlign;

    // Helper to safely find exact chunk locations in the WAV file
    int findChunk(Uint8List b, String chunkId) {
      if (b.length < 12) return -1;
      int offset = 12;
      while (offset + 8 <= b.length) {
        String id = String.fromCharCodes(b.sublist(offset, offset + 4));
        int size = ByteData.view(b.buffer).getUint32(offset + 4, Endian.little);
        if (id == chunkId) return offset;
        offset += 8 + size; // Move to next chunk
      }
      return -1;
    }
    
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
         
         // Dynamically find where the formats and data actually start
         int fmtOffset = findChunk(bytes, 'fmt ');
         int dataOffset = findChunk(bytes, 'data');
         
         if (fmtOffset != -1 && dataOffset != -1) {
           ByteData view = ByteData.view(bytes.buffer);
           
           if (sampleRate == null) {
             numChannels = view.getUint16(fmtOffset + 10, Endian.little);
             sampleRate = view.getUint32(fmtOffset + 12, Endian.little);
             byteRate = view.getUint32(fmtOffset + 16, Endian.little);
             blockAlign = view.getUint16(fmtOffset + 32, Endian.little);
             bitsPerSample = view.getUint16(fmtOffset + 34, Endian.little);
           }
           
           int dataSize = view.getUint32(dataOffset + 4, Endian.little);
           int actualAvailable = bytes.length - (dataOffset + 8);
           int readSize = (dataSize < actualAvailable && dataSize > 0) ? dataSize : actualAvailable;
           
           // Ensure we read complete audio frames to prevent static phase shifting
           readSize = readSize - (readSize % blockAlign!);
           
           if (readSize > 0) {
             // Extract pure audio data, leaving all metadata behind
             Uint8List audioData = bytes.sublist(dataOffset + 8, dataOffset + 8 + readSize);
             
             // --- VAD: PCM SILENCE STRIPPER ---
             if (bitsPerSample == 16) {
               ByteData chunkView = ByteData.view(audioData.buffer, audioData.offsetInBytes, audioData.length);
               int threshold = 150; // Amplitude threshold to detect "silence" (0-32767)
               
               // Find exact byte where speaking starts
               int firstAudible = 0;
               for (int j = 0; j <= audioData.length - blockAlign!; j += blockAlign!) {
                 if (chunkView.getInt16(j, Endian.little).abs() > threshold) {
                   firstAudible = j; break;
                 }
               }
               
               // Find exact byte where speaking stops
               int lastAudible = audioData.length - blockAlign!;
               for (int j = audioData.length - blockAlign!; j >= firstAudible; j -= blockAlign!) {
                 if (chunkView.getInt16(j, Endian.little).abs() > threshold) {
                   lastAudible = j; break;
                 }
               }
               
               // Add a tiny 50ms padding so we don't clip natural breaths/consonants
               int padBytes = (byteRate! * 0.05).toInt();
               padBytes = padBytes - (padBytes % blockAlign!); 
               
               firstAudible = (firstAudible - padBytes).clamp(0, audioData.length);
               lastAudible = (lastAudible + padBytes).clamp(0, audioData.length - blockAlign!);
               
               // Truncate the audio data to the exact spoken duration
               if (lastAudible >= firstAudible) {
                 audioData = audioData.sublist(firstAudible, lastAudible + blockAlign!);
               }
             }
             // --- END VAD ---

             int startBytes = totalDataBytes; 
             rawSink.add(audioData);
             totalDataBytes += audioData.length;
             
             int startMs = (startBytes * 1000) ~/ byteRate!;
             int endMs = (totalDataBytes * 1000) ~/ byteRate!;
             
             // Enforce a 15ms gap to stop Premiere/VLC from cascading overlap drift
             int displayEndMs = endMs - 15; 
             if (displayEndMs <= startMs) displayEndMs = startMs + 10;
             
             // Strip all newlines so the SRT parser block format doesn't break
             String safeText = textChunk.trim().replaceAll(RegExp(r'\s+'), ' ');
             
             srtContent.writeln(srtIndex++);
             srtContent.writeln('${_formatSrtTime(startMs)} --> ${_formatSrtTime(displayEndMs)}');
             srtContent.writeln(safeText);
             srtContent.writeln(); 
           }
         }
         await chunkFile.delete(); // Cleanup to save space
      }
    }
    
    await rawSink.flush();
    await rawSink.close();
    
    if (sampleRate != null && totalDataBytes > 0) {
       File finalWavFile = File(outputPath);
       var finalSink = finalWavFile.openWrite();
       
       // Build a pristine, mathematically perfect canonical header from scratch
       var header = ByteData(44);
       header.setUint8(0, 0x52); header.setUint8(1, 0x49); header.setUint8(2, 0x46); header.setUint8(3, 0x46); // RIFF
       header.setUint32(4, totalDataBytes + 36, Endian.little);
       header.setUint8(8, 0x57); header.setUint8(9, 0x41); header.setUint8(10, 0x56); header.setUint8(11, 0x45); // WAVE
       header.setUint8(12, 0x66); header.setUint8(13, 0x6D); header.setUint8(14, 0x74); header.setUint8(15, 0x20); // fmt 
       header.setUint32(16, 16, Endian.little);
       header.setUint16(20, 1, Endian.little);
       header.setUint16(22, numChannels!, Endian.little);
       header.setUint32(24, sampleRate!, Endian.little);
       header.setUint32(28, byteRate!, Endian.little);
       header.setUint16(32, blockAlign!, Endian.little);
       header.setUint16(34, bitsPerSample!, Endian.little);
       header.setUint8(36, 0x64); header.setUint8(37, 0x61); header.setUint8(38, 0x74); header.setUint8(39, 0x61); // data
       header.setUint32(40, totalDataBytes, Endian.little);
       
       finalSink.add(header.buffer.asUint8List());
       
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