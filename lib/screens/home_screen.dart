import 'dart:io';
import 'dart:async'; 
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

import '../models/voice_model.dart';
import '../services/piper_service.dart';

// Intent to handle Ctrl+F Search
class SearchIntent extends Intent { const SearchIntent(); }

// --- CUSTOM HIGHLIGHTING CONTROLLER ---
class HighlightingTextEditingController extends TextEditingController {
  int _highlightedChunkIndex = -1;
  List<String> _chunks = [];
  
  String _searchQuery = "";
  int _activeSearchMatchIndex = -1;

  int get highlightedChunkIndex => _highlightedChunkIndex;
  set highlightedChunkIndex(int value) {
    if (_highlightedChunkIndex != value) {
      _highlightedChunkIndex = value;
      notifyListeners();
    }
  }

  List<String> get chunks => _chunks;
  set chunks(List<String> value) {
    _chunks = value;
    notifyListeners();
  }

  String get searchQuery => _searchQuery;
  set searchQuery(String value) {
    if (_searchQuery != value) {
      _searchQuery = value;
      notifyListeners();
    }
  }

  int get activeSearchMatchIndex => _activeSearchMatchIndex;
  set activeSearchMatchIndex(int value) {
    if (_activeSearchMatchIndex != value) {
      _activeSearchMatchIndex = value;
      notifyListeners();
    }
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    // 1. Playback Chunk Highlighting
    if (_highlightedChunkIndex >= 0 && _highlightedChunkIndex < _chunks.length && _chunks.isNotEmpty) {
      List<TextSpan> spans = [];
      int currentIndex = 0;
      for (int i = 0; i < _chunks.length; i++) {
        final chunk = _chunks[i];
        if (currentIndex >= text.length) break;
        spans.add(TextSpan(
          text: chunk,
          style: i == _highlightedChunkIndex
              ? style?.copyWith(backgroundColor: Colors.blueGrey, color: Colors.white)
              : style,
        ));
        currentIndex += chunk.length;
      }
      return TextSpan(style: style, children: spans);
    }

    // 2. Ctrl+F Search Highlighting
    if (_searchQuery.isNotEmpty && _searchQuery.length >= 3) {
      List<TextSpan> spans = [];
      int start = 0;
      String lowerText = text.toLowerCase();
      String lowerQuery = _searchQuery.toLowerCase();
      int queryLen = lowerQuery.length;

      int index = lowerText.indexOf(lowerQuery, start);
      while (index >= 0) {
        if (index > start) {
          spans.add(TextSpan(text: text.substring(start, index), style: style));
        }
        bool isActive = index == _activeSearchMatchIndex;
        spans.add(TextSpan(
          text: text.substring(index, index + queryLen),
          style: style?.copyWith(
            backgroundColor: isActive ? Colors.orangeAccent : Colors.blueGrey.withOpacity(0.6),
            color: isActive ? Colors.black : Colors.white,
          ),
        ));
        start = index + queryLen;
        index = lowerText.indexOf(lowerQuery, start);
      }
      if (start < text.length) {
        spans.add(TextSpan(text: text.substring(start), style: style));
      }
      return TextSpan(style: style, children: spans);
    }

    // Default
    return TextSpan(style: style, text: text);
  }
}
// --------------------------------------

class EchoTextScreen extends StatefulWidget {
  const EchoTextScreen({super.key});

  @override
  State<EchoTextScreen> createState() => _EchoTextScreenState();
}

class _EchoTextScreenState extends State<EchoTextScreen> {
  final HighlightingTextEditingController _textController = HighlightingTextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _textFocusNode = FocusNode();
  
  // Search Bar State
  bool _isSearching = false;
  String _searchQuery = "";
  int _currentSearchMatch = -1;
  List<int> _searchMatchIndices = [];
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounceTimer; 

  late SharedPreferences _prefs;
  final PiperService _piperService = PiperService();

  bool _isGenerating = false;
  bool _isPlaying = false;
  
  // Save Progress State
  bool _isSaving = false;
  double _saveProgress = 0.0;
  String _saveEta = "";
  
  // Undo & Text State
  final List<String> _undoStack = [];
  String _lastSavedText = "";

  // Playback State
  List<String> _textChunks = [];
  int _currentChunkIndex = -1;
  int _playbackId = 0; 
  
  String _modelPath = '';
  VoiceModel? _selectedVoice;
  double _speechSpeed = 1.0;
  int _speakerId = 0;

  int _lastEditorTapTime = 0;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    _prefs = await SharedPreferences.getInstance();
    await _piperService.init();

    _textController.text = _prefs.getString('saved_text') ?? '';
    _lastSavedText = _textController.text;
    _speechSpeed = _prefs.getDouble('speech_speed') ?? 1.0;
    _speakerId = _prefs.getInt('speaker_id') ?? 0;

    _textController.addListener(() {
      // Fix: Only run heavy logic if the physical text changes (ignores cursor selection changes)
      if (_textController.text != _lastSavedText) {
        _lastSavedText = _textController.text;
        _prefs.setString('saved_text', _textController.text);
        if (_isSearching) _updateSearch(_searchController.text); 
        setState(() {}); 
      }
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
    _searchDebounceTimer?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _textFocusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _piperService.dispose();
    super.dispose();
  }

  // --- SEARCH LOGIC ---
  void _updateSearch(String query) {
    if (_searchDebounceTimer?.isActive ?? false) _searchDebounceTimer!.cancel();
    
    _searchDebounceTimer = Timer(const Duration(milliseconds: 400), () {
      _searchQuery = query;
      _searchMatchIndices.clear();
      
      if (query.length < 3) {
        _textController.searchQuery = "";
        _textController.activeSearchMatchIndex = -1;
        if (mounted) setState(() => _currentSearchMatch = -1);
        return;
      }

      String lowerText = _textController.text.toLowerCase();
      String lowerQuery = query.toLowerCase();
      int start = 0;
      int idx = lowerText.indexOf(lowerQuery, start);
      
      while(idx >= 0) {
        _searchMatchIndices.add(idx);
        start = idx + lowerQuery.length;
        idx = lowerText.indexOf(lowerQuery, start);
      }

      if (_searchMatchIndices.isNotEmpty) {
        _currentSearchMatch = 0;
      } else {
        _currentSearchMatch = -1;
      }

      _textController.searchQuery = query;
      _scrollToSearchMatch();
      if (mounted) setState(() {});
    });
  }

  void _nextSearchMatch() {
    if (_searchMatchIndices.isEmpty) return;
    _currentSearchMatch = (_currentSearchMatch + 1) % _searchMatchIndices.length;
    _scrollToSearchMatch();
  }

  void _prevSearchMatch() {
    if (_searchMatchIndices.isEmpty) return;
    _currentSearchMatch = (_currentSearchMatch - 1) % _searchMatchIndices.length;
    if (_currentSearchMatch < 0) _currentSearchMatch += _searchMatchIndices.length;
    _scrollToSearchMatch();
  }

  void _scrollToSearchMatch() {
    if (_currentSearchMatch >= 0 && _currentSearchMatch < _searchMatchIndices.length) {
      int offset = _searchMatchIndices[_currentSearchMatch];
      _textController.activeSearchMatchIndex = offset;
      
      _textController.selection = TextSelection(baseOffset: offset, extentOffset: offset + _searchQuery.length);
      
      // Fix: The "Focus Bounce" Hack. Forces the TextField to auto-scroll off-screen matches.
      bool wasFocused = _textFocusNode.hasFocus;
      if (!wasFocused) {
        _textFocusNode.requestFocus();
      }
      
      setState(() {});

      if (!wasFocused) {
        Future.delayed(const Duration(milliseconds: 50), () {
          if (mounted && _isSearching) {
            _searchFocusNode.requestFocus();
          }
        });
      }
    }
  }
  // --------------------

  // --- UNDO LOGIC ---
  void _saveStateForUndo() {
    final currentText = _textController.text;
    if (_undoStack.isEmpty || _undoStack.last != currentText) {
      _undoStack.add(currentText);
      if (_undoStack.length > 20) {
        _undoStack.removeAt(0); 
      }
      setState(() {});
    }
  }

  void _handleUndo() {
    if (_undoStack.isNotEmpty) {
      setState(() {
        _textController.text = _undoStack.removeLast();
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Action undone.')));
    }
  }

  List<String> _splitIntoSentences(String text) {
    final RegExp sentenceRegex = RegExp(r'.*?[.!?\n]+|.+');
    final Iterable<Match> matches = sentenceRegex.allMatches(text);
    return matches.map((m) => m.group(0)!).toList();
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

  Future<void> _startPlaybackFromCursor() async {
    if (!_piperService.isInitialized) return;

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
    int startIndex = _getChunkIndexFromCursor();

    FocusScope.of(context).unfocus();
    _startPlayback(startIndex);
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
      _textController.chunks = _textChunks;
      _textController.highlightedChunkIndex = startIndex;
      _textController.searchQuery = ""; 
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
              _textController.highlightedChunkIndex = idx;
              _isGenerating = false; 
            });
            _syncCursorToCurrentChunk();
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
          _textController.highlightedChunkIndex = -1;
          if (_isSearching) _textController.searchQuery = _searchQuery; 
        });
      }
    }
  }

  Future<void> _stopPlayback() async {
    if (_isPlaying || _isGenerating) {
      _playbackId++; 
      
      _syncCursorToCurrentChunk();
      
      await _piperService.stop();
      
      setState(() {
        _isPlaying = false;
        _isGenerating = false;
        _isSaving = false;
        _currentChunkIndex = -1;
        _textController.highlightedChunkIndex = -1;
        if (_isSearching) _textController.searchQuery = _searchQuery; 
      });
      
      Future.delayed(const Duration(milliseconds: 50), () {
        if (mounted) _textFocusNode.requestFocus();
      });
    }
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
      await _stopPlayback();
    }

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

    if (generateSubtitles == null) return; 

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

    setState(() {
      _isGenerating = true;
      _isSaving = true;
      _saveProgress = 0.0;
      _saveEta = "Calculating ETA...";
    });

    try {
      final outFile = File(outputFile);
      if (await outFile.exists()) await outFile.delete();

      List<String> chunksForExport = _splitIntoSentences(text);

      bool success = await _piperService.generateToFile(
        text,
        outputFile,
        modelPath: _modelPath,
        speed: _speechSpeed,
        speakerId: _speakerId,
        exportChunks: chunksForExport,
        isSubtitlesRequested: generateSubtitles,
        onProgress: (current, total, eta) {
          if (mounted) {
            setState(() {
              _saveProgress = current / total;
              _saveEta = "$current / $total chunks  •  ETA: $eta";
            });
          }
        }
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
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _isSaving = false;
        });
      }
    }
  }

  void _showFindReplaceDialog() {
    final findController = TextEditingController();
    final replaceController = TextEditingController();
    double minLineLength = 40; 
    bool smartJoinLabels = false; 
    bool stripSpecialChars = false; 

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              title: const Text('Magic Format Cleaner'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Quick Clean', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: Colors.blueGrey,
                      title: const Text('Strip emojis & non-standard symbols', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      value: stripSpecialChars,
                      onChanged: (val) {
                        setDialogState(() => stripSpecialChars = val ?? false);
                      },
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.auto_fix_high),
                      label: const Text('Clean AI Formats (Markdown, ***)'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade700,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 45),
                      ),
                      onPressed: () {
                        _saveStateForUndo(); 
                        
                        String currentText = _textController.text;
                        
                        if (stripSpecialChars) {
                          currentText = currentText.replaceAll(RegExp(r'[^\p{L}\p{N}\p{P}\p{Z}\n]', unicode: true), '');
                        }
                        
                        currentText = currentText.replaceAll(RegExp(r'\*\*|\*|__|_'), '');
                        currentText = currentText.replaceAll(RegExp(r'###|##|#'), '');
                        currentText = currentText.replaceAll(RegExp(r'^\s*Sure[!,]?\s*.*?:', multiLine: true, caseSensitive: false), '');
                        
                        _textController.text = currentText;
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Text cleaned!')));
                      },
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16.0),
                      child: Divider(color: Colors.white24),
                    ),

                    const Text('Fix Broken Lines (PDF/Copy-Paste)', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
                    const SizedBox(height: 8),
                    const Text(
                      'Joins chopped text back into paragraphs. Lines shorter than the minimum are kept on their own line (useful for titles or list items).', 
                      style: TextStyle(fontSize: 12, color: Colors.white54)
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Min Length to Join:', style: TextStyle(color: Colors.white70, fontSize: 14)),
                        Text('${minLineLength.toInt()} chars', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Slider(
                      value: minLineLength,
                      min: 10,
                      max: 100,
                      divisions: 90,
                      label: minLineLength.toInt().toString(),
                      onChanged: (val) {
                        setDialogState(() => minLineLength = val);
                      },
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: Colors.blueGrey,
                      title: const Text('Smart-join short labels (e.g. "Q", "A", "Speaker:")', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      value: smartJoinLabels,
                      onChanged: (val) {
                        setDialogState(() => smartJoinLabels = val ?? false);
                      },
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.wrap_text),
                      label: const Text('Fix Line Breaks'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade700,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 45),
                      ),
                      onPressed: () {
                        _saveStateForUndo(); 
                        
                        List<String> lines = _textController.text.split('\n');
                        List<String> result = [];
                        String currentParagraph = "";
                        
                        for (int i = 0; i < lines.length; i++) {
                          String line = lines[i].trimRight();
                          
                          if (line.trim().isEmpty) {
                            if (currentParagraph.isNotEmpty) {
                              result.add(currentParagraph);
                              currentParagraph = "";
                            }
                            result.add(""); 
                            continue;
                          }
                          
                          if (currentParagraph.isEmpty) {
                            currentParagraph = line.trimLeft();
                          } else {
                            currentParagraph += " ${line.trimLeft()}";
                          }
                          
                          bool shouldJoinToNext = false;
                          
                          if (line.length >= minLineLength.toInt()) {
                            shouldJoinToNext = true; 
                          } else if (smartJoinLabels && (line.length <= 3 || line.endsWith(':'))) {
                            shouldJoinToNext = true; 
                          }
                          
                          if (!shouldJoinToNext) {
                            result.add(currentParagraph);
                            currentParagraph = "";
                          }
                        }
                        
                        if (currentParagraph.isNotEmpty) {
                          result.add(currentParagraph);
                        }
                        
                        _textController.text = result.join('\n').replaceAll(RegExp(r' {2,}'), ' ');
                        
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Line breaks fixed!')));
                      },
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16.0),
                      child: Divider(color: Colors.white24),
                    ),

                    const Text('Find & Replace', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
                    const SizedBox(height: 8),
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
                      _saveStateForUndo(); 
                      _textController.text = _textController.text.replaceAll(findText, replaceController.text);
                      Navigator.pop(context);
                    }
                  },
                  child: const Text('Replace All'),
                ),
              ],
            );
          }
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

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        LogicalKeySet(Platform.isMacOS ? LogicalKeyboardKey.meta : LogicalKeyboardKey.control, LogicalKeyboardKey.keyF): const SearchIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          SearchIntent: CallbackAction<SearchIntent>(
            onInvoke: (SearchIntent intent) {
              setState(() {
                _isSearching = true;
              });
              _searchFocusNode.requestFocus();
              return null;
            },
          ),
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text('EchoText', style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.5)),
            centerTitle: false,
            actions: [
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Search (Ctrl+F)',
                onPressed: () {
                  setState(() { _isSearching = true; });
                  _searchFocusNode.requestFocus();
                },
              ),
              if (_isPlaying || _isGenerating) 
                IconButton(
                  icon: const Icon(Icons.stop),
                  tooltip: 'Stop playback/generation',
                  onPressed: _stopPlayback,
                )
              else
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  tooltip: 'Read text from cursor',
                  onPressed: isButtonDisabled ? null : _startPlaybackFromCursor,
                ),
              
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: 'Undo last bulk action',
                onPressed: _undoStack.isNotEmpty ? _handleUndo : null,
              ),
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
                  if (_textController.text.isNotEmpty) {
                    _saveStateForUndo(); 
                    _textController.clear();
                  }
                  if (_isPlaying || _isGenerating) _stopPlayback();
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
            padding: const EdgeInsets.only(left: 32.0, top: 16.0, right: 32.0, bottom: 24.0),
            child: Column(
              children: [
                // --- SEARCH BAR UI ---
                if (_isSearching)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16.0),
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2C),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12)
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.search, color: Colors.white54),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            decoration: const InputDecoration(
                              hintText: "Find in text... (min 3 chars)",
                              hintStyle: TextStyle(color: Colors.white38),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                            style: const TextStyle(color: Colors.white),
                            onChanged: _updateSearch,
                            onSubmitted: (_) => _nextSearchMatch(),
                          ),
                        ),
                        if (_searchMatchIndices.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0),
                            child: Text(
                              '${_currentSearchMatch + 1} of ${_searchMatchIndices.length}', 
                              style: const TextStyle(color: Colors.white54)
                            ),
                          )
                        else if (_searchQuery.isNotEmpty && _searchQuery.length >= 3)
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16.0),
                            child: Text('0 matches', style: TextStyle(color: Colors.white54)),
                          )
                        else if (_searchQuery.isNotEmpty && _searchQuery.length < 3)
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16.0),
                            child: Text('Type at least 3 chars...', style: TextStyle(color: Colors.white38, fontStyle: FontStyle.italic)),
                          ),
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_up, color: Colors.white),
                          onPressed: _prevSearchMatch,
                          tooltip: 'Previous match',
                        ),
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
                          onPressed: _nextSearchMatch,
                          tooltip: 'Next match',
                        ),
                        Container(width: 1, height: 24, color: Colors.white24, margin: const EdgeInsets.symmetric(horizontal: 8)),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () {
                            setState(() {
                              _isSearching = false;
                              _searchQuery = "";
                              _searchController.clear();
                              _textController.searchQuery = "";
                              _textController.activeSearchMatchIndex = -1;
                              _searchMatchIndices.clear();
                            });
                          },
                          tooltip: 'Close search',
                        ),
                      ],
                    ),
                  ),

                Expanded(
                  child: Stack(
                    children: [
                      // The Main Text Editor
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1E1E),
                            border: Border.all(color: Colors.white12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Listener(
                            onPointerDown: (event) {
                              int now = DateTime.now().millisecondsSinceEpoch;
                              if (now - _lastEditorTapTime < 300) {
                                Future.delayed(const Duration(milliseconds: 100), () {
                                  if (mounted && !_isPlaying && !_isGenerating) {
                                    _startPlaybackFromCursor();
                                  }
                                });
                              }
                              _lastEditorTapTime = now;
                            },
                            child: TextField(
                              controller: _textController,
                              scrollController: _scrollController, 
                              focusNode: _textFocusNode,           
                              maxLines: null,
                              expands: true,
                              readOnly: _isPlaying || _isGenerating, 
                              textAlignVertical: TextAlignVertical.top,
                              onTap: () {
                                if (_isPlaying) {
                                  int newIndex = _getChunkIndexFromCursor();
                                  if (newIndex != _currentChunkIndex) {
                                    _startPlayback(newIndex);
                                  }
                                }
                              },
                              contextMenuBuilder: (BuildContext context, EditableTextState editableTextState) {
                                final List<ContextMenuButtonItem> buttonItems = editableTextState.contextMenuButtonItems.toList();
                                if (!_isPlaying && !_isGenerating) {
                                  buttonItems.insert(0, ContextMenuButtonItem(
                                    label: '🔊 Read from here',
                                    onPressed: () {
                                      ContextMenuController.removeAny();
                                      _startPlaybackFromCursor();
                                    },
                                  ));
                                }
                                return AdaptiveTextSelectionToolbar.buttonItems(
                                  anchors: editableTextState.contextMenuAnchors,
                                  buttonItems: buttonItems,
                                );
                              },
                              decoration: const InputDecoration(
                                hintText: 'Paste or type text here to read...',
                                hintStyle: TextStyle(color: Colors.white38),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.all(24),
                              ),
                              style: const TextStyle(fontSize: 18, height: 1.6, color: Colors.white70),
                            ),
                          ),
                        ),
                      ),
                      
                      if (_isGenerating)
                        Positioned(
                          left: 1, 
                          right: 1, 
                          bottom: 1, 
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E1E).withOpacity(0.95),
                              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(15)),
                              border: const Border(top: BorderSide(color: Colors.white12)),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_isSaving) ...[
                                  LinearProgressIndicator(value: _saveProgress, backgroundColor: Colors.white10, color: Colors.blueGrey),
                                  const SizedBox(height: 8),
                                  Text(_saveEta, style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.bold)),
                                ] else ...[
                                  const LinearProgressIndicator(backgroundColor: Colors.white10, color: Colors.blueGrey),
                                ]
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}