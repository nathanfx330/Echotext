import 'package:flutter/material.dart';
import '../../utils/text_helpers.dart';

class MagicCleanerDialog extends StatefulWidget {
  final String initialText;

  const MagicCleanerDialog({
    super.key,
    required this.initialText,
  });

  @override
  State<MagicCleanerDialog> createState() => _MagicCleanerDialogState();
}

class _MagicCleanerDialogState extends State<MagicCleanerDialog> {
  late TextEditingController _findController;
  late TextEditingController _replaceController;
  
  double _minLineLength = 40; 
  bool _smartJoinLabels = false; 
  bool _stripSpecialChars = false;

  @override
  void initState() {
    super.initState();
    _findController = TextEditingController();
    _replaceController = TextEditingController();
  }

  @override
  void dispose() {
    _findController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  void _handleCleanAiFormats() {
    final newText = TextHelpers.quickClean(
      widget.initialText, 
      stripSpecialChars: _stripSpecialChars
    );
    Navigator.pop(context, newText);
  }

  void _handleFixLineBreaks() {
    final newText = TextHelpers.fixBrokenLines(
      widget.initialText, 
      minLineLength: _minLineLength, 
      smartJoinLabels: _smartJoinLabels
    );
    Navigator.pop(context, newText);
  }

  void _handleFindAndReplace() {
    final findText = _findController.text;
    if (findText.isNotEmpty) {
      final newText = widget.initialText.replaceAll(findText, _replaceController.text);
      Navigator.pop(context, newText);
    }
  }

  @override
  Widget build(BuildContext context) {
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
              value: _stripSpecialChars,
              onChanged: (val) {
                setState(() => _stripSpecialChars = val ?? false);
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
              onPressed: _handleCleanAiFormats,
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
                Text('${_minLineLength.toInt()} chars', style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            Slider(
              value: _minLineLength,
              min: 10,
              max: 100,
              divisions: 90,
              label: _minLineLength.toInt().toString(),
              onChanged: (val) {
                setState(() => _minLineLength = val);
              },
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: Colors.blueGrey,
              title: const Text('Smart-join short labels (e.g. "Q", "A", "Speaker:")', style: TextStyle(color: Colors.white70, fontSize: 13)),
              value: _smartJoinLabels,
              onChanged: (val) {
                setState(() => _smartJoinLabels = val ?? false);
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
              onPressed: _handleFixLineBreaks,
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16.0),
              child: Divider(color: Colors.white24),
            ),

            const Text('Find & Replace', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
            const SizedBox(height: 8),
            TextField(
              controller: _findController,
              decoration: const InputDecoration(labelText: 'Find', filled: true, fillColor: Colors.black12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _replaceController,
              decoration: const InputDecoration(labelText: 'Replace with', filled: true, fillColor: Colors.black12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context), // Returns null on cancel
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _handleFindAndReplace,
          child: const Text('Replace All'),
        ),
      ],
    );
  }
}