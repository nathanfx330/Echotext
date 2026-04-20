import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

import '../models/voice_model.dart';
import '../services/piper_service.dart';

class EchoTextScreen extends StatefulWidget {
  const EchoTextScreen({super.key});

  @override
  State<EchoTextScreen> createState() => _EchoTextScreenState();
}

class _EchoTextScreenState extends State<EchoTextScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _textFocusNode = FocusNode();
  
  late SharedPreferences _prefs;
  final PiperService _piperService = PiperService();

  bool _isGenerating = false;
  bool _isPlaying = false;
  
  // Bouncing Ball State
  List<String> _textChunks = [];
  int _currentChunkIndex = -1;
  int _playbackId = 0; 
  List<TapGestureRecognizer> _recognizers = []; 
  
  String _modelPath = '';
  VoiceModel? _selectedVoice;
  double _speechSpeed = 1.0;
  int _speakerId = 0;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    _prefs = await SharedPreferences.getInstance();
    await _piperService.init();

    _textController.text = _prefs.getString('saved_text') ?? '';
    _speechSpeed = _prefs.getDouble('speech_speed') ?? 1.0;
    _speakerId = _prefs.getInt('speaker_id') ?? 0;

    _textController.addListener(() {
      _prefs.setString('saved_text', _textController.text);
      setState(() {}); 
    });

    final savedModel = _prefs.getString('custom_model_path');
    if (savedModel != null && File(savedModel).existsSync()) {
      _modelPath = savedModel;
      try {
        _selectedVoice = _piperService.availableVoices.firstWhere((v) => v.path == _modelPath);
      } catch (e) {
        final custom = VoiceModel(name: 'Custom (${p.basename(_modelPath)})', path: _modelPath);
        _piperService.availableVoices.insert(0, custom);
        _selectedVoice = custom;
      }
    } else if (_piperService.availableVoices.isNotEmpty) {
      _modelPath = _piperService.availableVoices.first.path;
      _selectedVoice = _piperService.availableVoices.first;
    }

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (var r in _recognizers) {
      r.dispose();
    }
    _textController.dispose();
    _scrollController.dispose();
    _textFocusNode.dispose();
    _piperService.dispose();
    super.dispose();
  }

  List<String> _splitIntoSentences(String text) {
    final RegExp sentenceRegex = RegExp(r'.*?[.!?\n]+|.+');
    final Iterable<Match> matches = sentenceRegex.allMatches(text);
    return matches.map((m) => m.group(0)!).toList();
  }

  void _updateRecognizers() {
    for (var r in _recognizers) {
      r.dispose();
    }
    _recognizers = List.generate(_textChunks.length, (index) {
      return TapGestureRecognizer()
        ..onTap = () {
          if (_isPlaying && _currentChunkIndex != index) {
            _startPlayback(index);
          }
        };
    });
  }

  int _getChunkIndexFromCursor() {
    int cursorOffset = _textController.selection.baseOffset;
    if (cursorOffset <= 0) return 0; 

    int runningLength = 0;
    for (int i = 0; i < _textChunks.length; i++) {
      runningLength += _textChunks[i].length;
      if (cursorOffset < runningLength) {
        return i;
      }
    }
    return _textChunks.isNotEmpty ? _textChunks.length - 1 : 0;
  }

  void _syncCursorToCurrentChunk() {
    if (_currentChunkIndex >= 0 && _currentChunkIndex < _textChunks.length) {
      int offset = 0;
      for (int i = 0; i < _currentChunkIndex; i++) {
        offset += _textChunks[i].length;
      }
      _textController.selection = TextSelection.collapsed(offset: offset);
    }
  }

  Future<void> _startPlayback(int startIndex) async {
    final currentPlaybackId = ++_playbackId;

    if (_isPlaying || _isGenerating) {
      await _piperService.stop();
    }

    if (_textChunks.isEmpty) return;

    setState(() {
      _isGenerating = true;
      _isPlaying = true;
      _currentChunkIndex = startIndex;
    });

    try {
      await _piperService.playChunks(
        _textChunks,
        modelPath: _modelPath,
        speed: _speechSpeed,
        speakerId: _speakerId,
        startIndex: startIndex,
        onChunkStart: (idx) {
          if (mounted && _playbackId == currentPlaybackId) {
            setState(() {
              _currentChunkIndex = idx;
              _isGenerating = false; 
            });
          }
        },
      );
    } catch (e) {
      debugPrint("TTS Error: $e");
      if (mounted && _playbackId == currentPlaybackId) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error generating audio: $e')));
      }
    } finally {
      if (mounted && _playbackId == currentPlaybackId) {
        _syncCursorToCurrentChunk();
        setState(() {
          _isPlaying = false;
          _isGenerating = false;
          _currentChunkIndex = -1;
        });
      }
    }
  }

  Future<void> _handlePlayStop() async {
    if (!_piperService.isInitialized) return;

    if (_isPlaying || _isGenerating) {
      _playbackId++; 
      
      _syncCursorToCurrentChunk();
      
      await _piperService.stop();
      
      setState(() {
        _isPlaying = false;
        _isGenerating = false;
        _currentChunkIndex = -1;
      });
      
      Future.delayed(const Duration(milliseconds: 50), () {
        if (mounted) _textFocusNode.requestFocus();
      });
      return;
    }

    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter some text to read.')));
      return;
    }

    if (!File(_piperService.exePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not find Piper at: ${_piperService.exePath}')));
      return;
    }

    if (!File(_modelPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid model path. Please select one in Settings.')));
      return;
    }

    _textChunks = _splitIntoSentences(_textController.text);
    _updateRecognizers();

    int startIndex = _getChunkIndexFromCursor();

    FocusScope.of(context).unfocus();
    
    _startPlayback(startIndex);
  }

  Future<void> _handleSaveAudio() async {
    if (!_piperService.isInitialized || _isGenerating) return;

    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter some text to save.')));
      return;
    }

    if (!File(_piperService.exePath).existsSync() || !File(_modelPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Piper executable or model not found. Check settings.')));
      return;
    }

    if (_isPlaying) {
      _playbackId++;
      _syncCursorToCurrentChunk();
      await _piperService.stop();
      setState(() {
        _isPlaying = false;
        _currentChunkIndex = -1;
      });
    }

    // Ask user if they want perfectly timed subtitles generated
    bool? generateSubtitles = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Generate Subtitles?'),
          content: const Text(
            'Do you want to generate a perfectly timed .srt subtitle file alongside your audio?\n\n'
            'Note: This takes slightly longer as the audio is generated and mathematically stitched sentence-by-sentence.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No, Just Audio', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueGrey.shade700,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Yes, Audio + .SRT'),
            ),
          ],
        );
      },
    );

    if (generateSubtitles == null) return; // User closed dialog

    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Audio As...',
      fileName: 'echotext_audio.wav',
      type: FileType.custom,
      allowedExtensions: ['wav'],
    );

    if (outputFile == null) return;

    if (!outputFile.toLowerCase().endsWith('.wav')) {
      outputFile += '.wav';
    }

    setState(() => _isGenerating = true);

    try {
      final outFile = File(outputFile);
      if (await outFile.exists()) await outFile.delete();

      List<String>? chunksForSubtitles = generateSubtitles ? _splitIntoSentences(text) : null;

      bool success = await _piperService.generateToFile(
        text,
        outputFile,
        modelPath: _modelPath,
        speed: _speechSpeed,
        speakerId: _speakerId,
        chunksForSubtitles: chunksForSubtitles,
      );

      if (success && mounted && await outFile.exists()) {
        String msg = generateSubtitles 
            ? 'Audio and Subtitles (.srt) successfully saved to:\n${outFile.parent.path}'
            : 'Audio successfully saved to:\n$outputFile';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      } else {
        throw Exception('Failed to write file or process exited with error.');
      }
    } catch (e) {
      debugPrint("Save TTS Error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving audio: $e')));
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  void _showFindReplaceDialog() {
    final findController = TextEditingController();
    final replaceController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Clean Text / Find & Replace'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Quick Clean AI Formats (Markdown, ***)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey.shade700,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 45),
                ),
                onPressed: () {
                  String currentText = _textController.text;
                  currentText = currentText.replaceAll(RegExp(r'\*\*|\*|__|_'), '');
                  currentText = currentText.replaceAll(RegExp(r'###|##|#'), '');
                  currentText = currentText.replaceAll(RegExp(r'^\s*Sure[!,]?\s*.*?:', multiLine: true, caseSensitive: false), '');
                  
                  _textController.text = currentText;
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('AI formatting removed!')));
                },
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16.0),
                child: Divider(color: Colors.white24),
              ),
              TextField(
                controller: findController,
                decoration: const InputDecoration(labelText: 'Find', filled: true, fillColor: Colors.black12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: replaceController,
                decoration: const InputDecoration(labelText: 'Replace with', filled: true, fillColor: Colors.black12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final findText = findController.text;
                if (findText.isNotEmpty) {
                  _textController.text = _textController.text.replaceAll(findText, replaceController.text);
                  Navigator.pop(context);
                }
              },
              child: const Text('Replace All'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickCustomModel() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['onnx'],
        dialogTitle: 'Select Piper ONNX Model');

    if (result != null && result.files.single.path != null) {
      final pickedPath = result.files.single.path!;
      
      setState(() {
        _modelPath = pickedPath;
        try {
          _selectedVoice = _piperService.availableVoices.firstWhere((v) => v.path == _modelPath);
        } catch (e) {
          final customVoice = VoiceModel(
            name: 'Custom (${p.basename(_modelPath)})', 
            path: _modelPath
          );
          _piperService.availableVoices.insert(0, customVoice);
          _selectedVoice = customVoice;
        }
      });
      
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StatefulBuilder(builder: (context, setSheetState) {
          return Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Voice Settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),

                const Text('Current Model:', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<VoiceModel>(
                            isExpanded: true,
                            value: _selectedVoice,
                            dropdownColor: const Color(0xFF2C2C2C),
                            hint: const Text('No voices found in model/ folder'),
                            items: _piperService.availableVoices.map((voice) {
                              return DropdownMenuItem<VoiceModel>(
                                value: voice,
                                child: Text(voice.name, overflow: TextOverflow.ellipsis),
                              );
                            }).toList(),
                            onChanged: (VoiceModel? newVoice) {
                              if (newVoice != null) {
                                setSheetState(() {
                                  _selectedVoice = newVoice;
                                  _modelPath = newVoice.path;
                                });
                                setState(() => _modelPath = newVoice.path);
                                _prefs.setString('custom_model_path', newVoice.path);
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
                      child: IconButton(
                        icon: const Icon(Icons.folder_open),
                        tooltip: 'Load external .onnx model',
                        onPressed: () async {
                          await _pickCustomModel();
                          setSheetState(() {});
                        },
                      ),
                    )
                  ],
                ),
                const Divider(height: 32, color: Colors.white12),
                
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Speed (Length Scale):', style: TextStyle(color: Colors.white70)),
                    Text('${_speechSpeed.toStringAsFixed(2)}x'),
                  ],
                ),
                Slider(
                  value: _speechSpeed,
                  min: 0.5, max: 2.0, divisions: 15,
                  label: _speechSpeed.toStringAsFixed(2),
                  onChanged: (val) {
                    setSheetState(() => _speechSpeed = val);
                    setState(() => _speechSpeed = val);
                    _prefs.setDouble('speech_speed', val);
                  },
                ),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Speaker ID (Multispeaker):', style: TextStyle(color: Colors.white70)),
                    Text(_speakerId.toString()),
                  ],
                ),
                Slider(
                  value: _speakerId.toDouble(),
                  min: 0, max: 50, divisions: 50,
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
        });
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    final isButtonDisabled = !_piperService.isInitialized || (_textController.text.trim().isEmpty && !_isPlaying && !_isGenerating);
    final isSaveDisabled = isButtonDisabled || _isGenerating || _isPlaying;

    return Scaffold(
      appBar: AppBar(
        title: const Text('EchoText', style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.5)),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_fix_high),
            tooltip: 'Clean AI Formatting / Find & Replace',
            onPressed: () => _showFindReplaceDialog(),
          ),
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
        padding: const EdgeInsets.only(left: 32.0, top: 16.0, right: 32.0, bottom: 96.0),
        child: Column(
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  border: Border.all(color: Colors.white12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: !_isPlaying 
                ? TextField(
                    controller: _textController,
                    scrollController: _scrollController, 
                    focusNode: _textFocusNode,           
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: 'Paste or type text here to read...',
                      hintStyle: TextStyle(color: Colors.white38),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(24),
                    ),
                    style: const TextStyle(fontSize: 18, height: 1.6, color: Colors.white70),
                  )
                : SingleChildScrollView(
                    controller: _scrollController, 
                    padding: const EdgeInsets.all(24),
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 18, height: 1.6, color: Colors.white70),
                        children: List.generate(_textChunks.length, (index) {
                          final isCurrent = _currentChunkIndex == index;
                          return TextSpan(
                            text: _textChunks[index],
                            style: isCurrent
                                ? const TextStyle(
                                    backgroundColor: Colors.blueGrey,
                                    color: Colors.white,
                                  )
                                : null,
                            mouseCursor: SystemMouseCursors.click,
                            recognizer: _recognizers.isNotEmpty && index < _recognizers.length 
                                ? _recognizers[index] 
                                : null,
                          );
                        }),
                      ),
                    ),
                  ),
              ),
            ),
            if (_isGenerating) ...[
              const SizedBox(height: 24),
              const LinearProgressIndicator(backgroundColor: Colors.white10, color: Colors.blueGrey),
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
      ),
    );
  }
}