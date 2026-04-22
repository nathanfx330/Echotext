import 'package:flutter/material.dart';

// Intent to handle Ctrl+F Search
class SearchIntent extends Intent { 
  const SearchIntent(); 
}

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