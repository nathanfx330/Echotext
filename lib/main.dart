import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EchoTextApp());
}

class EchoTextApp extends StatelessWidget {
  const EchoTextApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EchoText',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueGrey,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
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
  late SharedPreferences _prefs;

  Process? _piperProcess;
  
  bool _isGenerating = false;
  bool _isPlaying = false;
  bool _isInitialized = false;
  
  late String _piperExePath;
  String _modelPath = '';
  
  // Piper Settings
  double _speechSpeed = 1.0; // Piper's length_scale
  int _speakerId = 0;

  @override
  void initState() {
    super.initState();
    _initApp();

    // Listen for when audio finishes playing
    _audioPlayer.onPlayerComplete.listen((event) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
        });
      }
    });
  }

  Future<void> _initApp() async {
    _prefs = await SharedPreferences.getInstance();
    
    // Load saved preferences
    _textController.text = _prefs.getString('saved_text') ?? '';
    _speechSpeed = _prefs.getDouble('speech_speed') ?? 1.0;
    _speakerId = _prefs.getInt('speaker_id') ?? 0;
    
    // Auto-save text as user types AND trigger UI rebuild to enable Play/Save buttons
    _textController.addListener(() {
      _prefs.setString('saved_text', _textController.text);
      setState(() {}); 
    });

    await _initPaths();
  }

  Future<void> _initPaths() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final currentDir = Directory.current.path;
    final exeName = Platform.isWindows ? 'piper.exe' : 'piper';
    
    String potentialPiperProd = p.join(exeDir, 'piper', exeName);
    String potentialPiperDev = p.join(currentDir, 'piper', exeName);
    
    if (File(potentialPiperProd).existsSync()) {
      _piperExePath = potentialPiperProd;
      _modelPath = p.join(exeDir, 'model', 'piper.onnx');
    } else {
      _piperExePath = potentialPiperDev;
      _modelPath = p.join(currentDir, 'model', 'piper.onnx');
    }

    // Override with custom model if user saved one previously
    final savedModel = _prefs.getString('custom_model_path');
    if (savedModel != null && File(savedModel).existsSync()) {
      _modelPath = savedModel;
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
    _piperProcess?.kill();
    _textController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _handlePlayStop() async {
    if (!_isInitialized) return;

    // STOP LOGIC
    if (_isPlaying || _isGenerating) {
      _piperProcess?.kill();
      await _audioPlayer.stop();
      setState(() {
        _isPlaying = false;
        _isGenerating = false;
      });
      return;
    }

    // PLAY LOGIC
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter some text to read.')),
      );
      return;
    }

    if (!File(_piperExePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not find Piper at: $_piperExePath')),
      );
      return;
    }
    if (!File(_modelPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not find Model at: $_modelPath\nPlease select one in Settings.')),
      );
      return;
    }

    setState(() => _isGenerating = true);

    try {
      final tempDir = await getTemporaryDirectory();
      final outputPath = p.join(tempDir.path, 'echotext_output.wav');
      final outFile = File(outputPath);
      
      if (await outFile.exists()) await outFile.delete();

      // Build arguments
      List<String> args = [
        '--model', _modelPath,
        '--output_file', outputPath,
        '--length_scale', _speechSpeed.toStringAsFixed(2),
      ];

      // Only pass speaker argument if > 0 to avoid crashing single-speaker models
      if (_speakerId > 0) {
        args.addAll(['--speaker', _speakerId.toString()]);
      }

      _piperProcess = await Process.start(_piperExePath, args);

      // Capture stderr for debugging
      _piperProcess!.stderr.transform(SystemEncoding().decoder).listen((data) {
        debugPrint("Piper Log: $data");
      });

      // Write text to stdin
      _piperProcess!.stdin.write(text);
      await _piperProcess!.stdin.close();

      final exitCode = await _piperProcess!.exitCode;

      // Ensure we weren't cancelled mid-generation
      if (_isGenerating) {
        if (exitCode == 0 && await outFile.exists()) {
          setState(() {
            _isGenerating = false;
            _isPlaying = true;
          });
          await _audioPlayer.play(DeviceFileSource(outputPath));
        } else {
          throw Exception('Piper exited with code $exitCode');
        }
      }

    } catch (e) {
      debugPrint("TTS Error: $e");
      if (mounted && _isGenerating) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating audio: $e')),
        );
        setState(() => _isGenerating = false);
      }
    }
  }

  Future<void> _handleSaveAudio() async {
    if (!_isInitialized || _isGenerating) return;

    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter some text to save.')),
      );
      return;
    }

    if (!File(_piperExePath).existsSync() || !File(_modelPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Piper executable or model not found. Check settings.')),
      );
      return;
    }

    // Stop playback if currently playing
    if (_isPlaying) {
      await _audioPlayer.stop();
      setState(() => _isPlaying = false);
    }

    // Prompt user for save location
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Audio As...',
      fileName: 'echotext_audio.wav',
      type: FileType.custom,
      allowedExtensions: ['wav'],
    );

    if (outputFile == null) {
      return; // User canceled
    }

    // Ensure extension is .wav
    if (!outputFile.toLowerCase().endsWith('.wav')) {
      outputFile += '.wav';
    }

    setState(() => _isGenerating = true);

    try {
      final outFile = File(outputFile);
      if (await outFile.exists()) await outFile.delete();

      List<String> args = [
        '--model', _modelPath,
        '--output_file', outputFile,
        '--length_scale', _speechSpeed.toStringAsFixed(2),
      ];

      if (_speakerId > 0) {
        args.addAll(['--speaker', _speakerId.toString()]);
      }

      _piperProcess = await Process.start(_piperExePath, args);

      _piperProcess!.stderr.transform(SystemEncoding().decoder).listen((data) {
        debugPrint("Piper Save Log: $data");
      });

      _piperProcess!.stdin.write(text);
      await _piperProcess!.stdin.close();

      final exitCode = await _piperProcess!.exitCode;

      if (_isGenerating) {
        if (exitCode == 0 && await outFile.exists()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Audio successfully saved to:\n$outputFile')),
            );
          }
        } else {
          throw Exception('Piper exited with code $exitCode');
        }
      }
    } catch (e) {
      debugPrint("Save TTS Error: $e");
      if (mounted && _isGenerating) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving audio: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  Future<void> _pickCustomModel() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['onnx'],
      dialogTitle: 'Select Piper ONNX Model'
    );

    if (result != null && result.files.single.path != null) {
      setState(() => _modelPath = result.files.single.path!);
      await _prefs.setString('custom_model_path', _modelPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Model updated successfully!')),
        );
      }
    }
  }

  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Voice Settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 24),
                  
                  // Model Selection
                  const Text('Current Model:', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          p.basename(_modelPath).isEmpty ? 'None selected' : p.basename(_modelPath),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await _pickCustomModel();
                          setSheetState((){});
                        },
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Change'),
                      )
                    ],
                  ),
                  const Divider(height: 32, color: Colors.white12),
                  
                  // Speed Control
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Speed (Length Scale):', style: TextStyle(color: Colors.white70)),
                      Text('${_speechSpeed.toStringAsFixed(2)}x'),
                    ],
                  ),
                  Slider(
                    value: _speechSpeed,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: _speechSpeed.toStringAsFixed(2),
                    onChanged: (val) {
                      setSheetState(() => _speechSpeed = val);
                      setState(() => _speechSpeed = val);
                      _prefs.setDouble('speech_speed', val);
                    },
                  ),

                  // Speaker ID Control
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Speaker ID (Multispeaker):', style: TextStyle(color: Colors.white70)),
                      Text(_speakerId.toString()),
                    ],
                  ),
                  Slider(
                    value: _speakerId.toDouble(),
                    min: 0,
                    max: 50, // Expanded to 50, some models have many speakers
                    divisions: 50,
                    label: _speakerId.toString(),
                    onChanged: (val) {
                      setSheetState(() => _speakerId = val.toInt());
                      setState(() => _speakerId = val.toInt());
                      _prefs.setInt('speaker_id', val.toInt());
                    },
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    // Button is disabled if not initialized, OR if there's no text AND we aren't currently playing/generating.
    final isButtonDisabled = !_isInitialized || (_textController.text.trim().isEmpty && !_isPlaying && !_isGenerating);
    final isSaveDisabled = isButtonDisabled || _isGenerating;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'EchoText',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.5),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'Save Audio (.wav)',
            onPressed: isSaveDisabled ? null : _handleSaveAudio,
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Clear Text',
            onPressed: () {
              _textController.clear();
              if (_isPlaying || _isGenerating) _handlePlayStop();
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _showSettingsSheet,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.only(left: 32.0, top: 32.0, right: 32.0, bottom: 96.0),
        child: Column(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E), 
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
                    contentPadding: EdgeInsets.all(24), 
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
        onPressed: isButtonDisabled ? null : _handlePlayStop,
        icon: Icon((_isPlaying || _isGenerating) ? Icons.stop : Icons.play_arrow),
        label: Text((_isPlaying || _isGenerating) ? 'Stop' : 'Read Text'),
        backgroundColor: (_isPlaying || _isGenerating) ? Colors.red.shade700 : Colors.blueGrey.shade700,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
    );
  }
}