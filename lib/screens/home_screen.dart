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
import '../controllers/highlighting_text_controller.dart';
import '../utils/text_helpers.dart';
import '../widgets/dialogs/magic_cleaner_dialog.dart';
import '../widgets/sheets/settings_sheet.dart';
import '../widgets/editor/search_bar_header.dart';
import '../widgets/editor/export_progress_overlay.dart'; 

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
  
  // 20-Step Undo Stack State
  final List<String> _undoStack = [];
  bool _isUndoing = false;
  String _lastSavedText = "";

  // Playback State
  List<String> _textChunks = [];
  int _currentChunkIndex = -1;
  int _playbackId = 0; 
  
  String _modelPath = '';
  VoiceModel? _selectedVoice;
  double _speechSpeed = 1.0;
  int _speakerId = 0;
  bool _useGpu = false;

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
    _useGpu = _prefs.getBool('use_gpu') ?? false;

    _textController.addListener(() {
      if (_textController.text != _lastSavedText) {
        // Only save to undo stack if the user typed it, not if we triggered an Undo
        if (!_isUndoing && _lastSavedText.isNotEmpty) {
          _undoStack.add(_lastSavedText);
          if (_undoStack.length > 20) _undoStack.removeAt(0); // Keep max 20 steps
        }
        
        _lastSavedText = _textController.text;
        _prefs.setString('saved_text', _textController.text);
        if (_isSearching) _updateSearch(_searchController.text); 
        
        setState(() {}); // Rebuild UI to update Undo button visibility
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

  // --- UNDO LOGIC ---
  void _performUndo() {
    if (_undoStack.isNotEmpty) {
      setState(() => _isUndoing = true);
      String previousText = _undoStack.removeLast();
      _textController.text = previousText;
      
      // Reset cursor to end of text
      _textController.selection = TextSelection.collapsed(offset: previousText.length);
      
      Future.microtask(() => setState(() => _isUndoing = false));
    }
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

    _textChunks = TextHelpers.splitIntoSentences(_textController.text);
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
        useGpu: _useGpu,
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

      // ALWAYS chunk the text! This gives us VAD safety, memory safety, and the ETA bar!
      List<String> chunksForExport = TextHelpers.splitIntoSentences(text);

      bool success = await _piperService.generateToFile(
        text,
        outputFile,
        modelPath: _modelPath,
        speed: _speechSpeed,
        speakerId: _speakerId,
        useGpu: _useGpu,
        exportChunks: chunksForExport,
        isSubtitlesRequested: generateSubtitles, // True or False, piper_service handles it
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

  Future<void> _showFindReplaceDialog() async {
    final String? newText = await showDialog<String>(
      context: context,
      builder: (context) => MagicCleanerDialog(initialText: _textController.text),
    );

    if (newText != null && newText != _textController.text) {
      setState(() {
        _textController.text = newText;
      });
    }
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
          return SettingsSheet(
            selectedVoice: _selectedVoice,
            availableVoices: _piperService.availableVoices,
            speechSpeed: _speechSpeed,
            speakerId: _speakerId,
            useGpu: _useGpu,
            onVoiceSelected: (newVoice) {
              setSheetState(() => _selectedVoice = newVoice);
              setState(() {
                _selectedVoice = newVoice;
                _modelPath = newVoice.path;
              });
              _prefs.setString('custom_model_path', newVoice.path);
            },
            onSpeedChanged: (val) {
              setSheetState(() => _speechSpeed = val);
              setState(() => _speechSpeed = val);
              _prefs.setDouble('speech_speed', val);
            },
            onSpeakerIdChanged: (val) {
              setSheetState(() => _speakerId = val);
              setState(() => _speakerId = val);
              _prefs.setInt('speaker_id', val);
            },
            onGpuChanged: (val) async {
              if (val) {
                // User is turning it ON. Test it first.
                if (!File(_modelPath).existsSync()) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a valid model first.')));
                  return;
                }
                
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Testing GPU compatibility...')));
                
                bool gpuWorks = await _piperService.testGpuSupport(_modelPath);
                
                if (gpuWorks) {
                  setSheetState(() => _useGpu = true);
                  setState(() => _useGpu = true);
                  _prefs.setBool('use_gpu', true);
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('GPU Acceleration Enabled!')));
                } else {
                  setSheetState(() => _useGpu = false);
                  setState(() => _useGpu = false);
                  _prefs.setBool('use_gpu', false);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Failed to enable GPU. Missing NVIDIA CUDA or ONNX Runtime libraries.'),
                      backgroundColor: Colors.redAccent,
                    ));
                  }
                }
              } else {
                // User is turning it OFF. Just turn it off safely.
                setSheetState(() => _useGpu = false);
                setState(() => _useGpu = false);
                _prefs.setBool('use_gpu', false);
              }
            },
            onPickCustomModel: () async {
              await _pickCustomModel();
              setSheetState(() {});
            },
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
                icon: const Icon(Icons.auto_fix_high),
                tooltip: 'Clean AI Formatting / Find & Replace',
                onPressed: () => _showFindReplaceDialog(),
              ),
              IconButton(
                icon: const Icon(Icons.save_alt),
                tooltip: 'Save Audio (.wav)',
                onPressed: isSaveDisabled ? null : _handleSaveAudio,
              ),

              // --- DYNAMIC UNDO/CLEAR BUTTONS ---
              if (_undoStack.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.undo),
                  tooltip: 'Undo',
                  onPressed: _performUndo,
                ),
              
              IconButton(
                icon: const Icon(Icons.clear_all),
                tooltip: 'Clear Text',
                onPressed: () {
                  if (_textController.text.isNotEmpty) {
                    setState(() {
                      _textController.clear();
                    });
                    if (_isPlaying || _isGenerating) _stopPlayback();
                  }
                },
              ),
              // ---------------------------------

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
                if (_isSearching)
                  SearchBarHeader(
                    searchController: _searchController,
                    searchFocusNode: _searchFocusNode,
                    searchQuery: _searchQuery,
                    currentMatchIndex: _currentSearchMatch,
                    totalMatches: _searchMatchIndices.length,
                    onSearchChanged: _updateSearch,
                    onSearchSubmitted: _nextSearchMatch,
                    onPrevMatch: _prevSearchMatch,
                    onNextMatch: _nextSearchMatch,
                    onClose: () {
                      setState(() {
                        _isSearching = false;
                        _searchQuery = "";
                        _searchController.clear();
                        _textController.searchQuery = "";
                        _textController.activeSearchMatchIndex = -1;
                        _searchMatchIndices.clear();
                      });
                    },
                  ),

                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1E1E),
                            border: Border.all(color: Colors.white12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: GestureDetector(
                            onDoubleTap: () {
                              if (mounted && !_isPlaying && !_isGenerating) {
                                _startPlaybackFromCursor();
                              }
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
                        ExportProgressOverlay(
                          isSaving: _isSaving,
                          saveProgress: _saveProgress,
                          saveEta: _saveEta,
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