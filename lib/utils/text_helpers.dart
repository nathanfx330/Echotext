class TextHelpers {
  /// Splits a large block of text into playback chunks (sentences/paragraphs)
  static List<String> splitIntoSentences(String text) {
    final RegExp sentenceRegex = RegExp(r'.*?[.!?\n]+|.+');
    final Iterable<Match> matches = sentenceRegex.allMatches(text);
    return matches.map((m) => m.group(0)!).toList();
  }

  /// Strips AI markdown, bolding, headers, and optionally special characters/emojis
  static String quickClean(String text, {required bool stripSpecialChars}) {
    String currentText = text;
    
    if (stripSpecialChars) {
      currentText = currentText.replaceAll(RegExp(r'[^\p{L}\p{N}\p{P}\p{Z}\n]', unicode: true), '');
    }
    
    currentText = currentText.replaceAll(RegExp(r'\*\*|\*|__|_'), '');
    currentText = currentText.replaceAll(RegExp(r'###|##|#'), '');
    currentText = currentText.replaceAll(RegExp(r'^\s*Sure[!,]?\s*.*?:', multiLine: true, caseSensitive: false), '');
    
    return currentText;
  }

  /// Joins chopped text back into paragraphs (Fixes PDF copy-paste formatting)
  static String fixBrokenLines(String text, {required double minLineLength, required bool smartJoinLabels}) {
    List<String> lines = text.split('\n');
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
    
    return result.join('\n').replaceAll(RegExp(r' {2,}'), ' ');
  }
}