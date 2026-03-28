import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

void main() {
  runApp(const EchoTextApp());
}

class EchoTextApp extends StatelessWidget {
  const EchoTextApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EchoText',
      theme: ThemeData(
        // Clean dark theme without the purple tint
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueGrey, 
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF121212), // Deep dark background
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF121212),
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      home: const EchoTextScreen(),
    );
  }
}

class EchoTextScreen extends StatefulWidget {
  const EchoTextScreen({super.key});

  @override
  State<EchoTextScreen> createState() => _EchoTextScreenState();
}

class _EchoTextScreenState extends State<EchoTextScreen> {
  final TextEditingController _textController = TextEditingController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  
  bool _isGenerating = false;
  bool _isPlaying = false;
  bool _isInitialized = false;
  
  late String _piperExePath;
  late String _modelPath;

  @override
  void initState() {
    super.initState();
    
    _initPaths();

    // Listen for when audio finishes playing
    _audioPlayer.onPlayerComplete.listen((event) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
        });
      }
    });
  }

  Future<void> _initPaths() async {
    // 1. Find the executable directory (used in built/release apps)
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    
    // 2. Find the current working directory (used during 'flutter run' development)
    final currentDir = Directory.current.path;
    
    // Account for Windows vs Unix executable extensions
    final exeName = Platform.isWindows ? 'piper.exe' : 'piper';
    
    // Check if piper is bundled next to the executable (Production)
    // Otherwise fallback to the current directory (Development)
    String potentialPiperProd = p.join(exeDir, 'piper', exeName);
    String potentialPiperDev = p.join(currentDir, 'piper', exeName);
    
    if (File(potentialPiperProd).existsSync()) {
      _piperExePath = potentialPiperProd;
      _modelPath = p.join(exeDir, 'model', 'piper.onnx');
    } else {
      _piperExePath = potentialPiperDev;
      _modelPath = p.join(currentDir, 'model', 'piper.onnx');
    }

    // Ensure Unix systems allow the piper binary to execute
    if (!Platform.isWindows && File(_piperExePath).existsSync()) {
      await Process.run('chmod', ['+x', _piperExePath]);
    }

    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _handlePlayStop() async {
    if (!_isInitialized) return;

    if (_isPlaying) {
      await _audioPlayer.stop();
      setState(() => _isPlaying = false);
      return;
    }

    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter some text to read.')),
      );
      return;
    }

    // Verify files exist before trying to run
    if (!File(_piperExePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not find Piper at: $_piperExePath')),
      );
      return;
    }
    if (!File(_modelPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not find Model at: $_modelPath')),
      );
      return;
    }

    setState(() => _isGenerating = true);

    try {
      // Get cross-platform temporary directory safely
      final tempDir = await getTemporaryDirectory();
      final outputPath = p.join(tempDir.path, 'echotext_output.wav');
      final outFile = File(outputPath);
      
      if (await outFile.exists()) await outFile.delete();

      // Run Piper Engine via Process
      var process = await Process.start(_piperExePath, [
        '--model', _modelPath,
        '--output_file', outputPath
      ]);

      // Capture stderr for debugging (helps identify missing espeak data, etc.)
      process.stderr.transform(SystemEncoding().decoder).listen((data) {
        debugPrint("Piper Log: $data");
      });

      // Pipe the text into Piper
      process.stdin.write(text);
      await process.stdin.close();

      final exitCode = await process.exitCode;

      if (exitCode == 0 && await outFile.exists()) {
        await _audioPlayer.play(DeviceFileSource(outputPath));
        setState(() => _isPlaying = true);
      } else {
        throw Exception('Piper exited with code $exitCode');
      }

    } catch (e) {
      debugPrint("TTS Error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating audio: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'EchoText',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.5),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Clear Text',
            onPressed: () {
              _textController.clear();
              _audioPlayer.stop();
              setState(() => _isPlaying = false);
            },
          ),
          const SizedBox(width: 16), // Add a little padding to the right
        ],
      ),
      body: Padding(
        // Added extra bottom padding (96.0) so the text box doesn't slide under the button
        padding: const EdgeInsets.only(left: 32.0, top: 32.0, right: 32.0, bottom: 96.0),
        child: Column(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E), // Subtle contrast from scaffold
                  border: Border.all(color: Colors.white12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: TextField(
                  controller: _textController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    hintText: 'Paste or type text here to read...',
                    hintStyle: TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(24), // Inner padding for text
                  ),
                  style: const TextStyle(
                    fontSize: 18, 
                    height: 1.6,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
            if (_isGenerating) ...[
              const SizedBox(height: 24),
              const LinearProgressIndicator(
                backgroundColor: Colors.white10,
                color: Colors.blueGrey,
              ),
            ],
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_isGenerating || !_isInitialized) ? null : _handlePlayStop,
        icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
        label: Text(_isPlaying ? 'Stop' : (_isGenerating ? 'Synthesizing...' : 'Read Text')),
        backgroundColor: _isPlaying ? Colors.red.shade700 : Colors.blueGrey.shade700,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
    );
  }
}