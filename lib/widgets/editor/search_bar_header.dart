import 'package:flutter/material.dart';

class SearchBarHeader extends StatelessWidget {
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String searchQuery;
  final int currentMatchIndex;
  final int totalMatches;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchSubmitted;
  final VoidCallback onPrevMatch;
  final VoidCallback onNextMatch;
  final VoidCallback onClose;

  const SearchBarHeader({
    super.key,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchQuery,
    required this.currentMatchIndex,
    required this.totalMatches,
    required this.onSearchChanged,
    required this.onSearchSubmitted,
    required this.onPrevMatch,
    required this.onNextMatch,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
              controller: searchController,
              focusNode: searchFocusNode,
              decoration: const InputDecoration(
                hintText: "Find in text... (min 3 chars)",
                hintStyle: TextStyle(color: Colors.white38),
                border: InputBorder.none,
                isDense: true,
              ),
              style: const TextStyle(color: Colors.white),
              onChanged: onSearchChanged,
              onSubmitted: (_) => onSearchSubmitted(),
            ),
          ),
          if (totalMatches > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                '${currentMatchIndex + 1} of $totalMatches', 
                style: const TextStyle(color: Colors.white54)
              ),
            )
          else if (searchQuery.isNotEmpty && searchQuery.length >= 3)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Text('0 matches', style: TextStyle(color: Colors.white54)),
            )
          else if (searchQuery.isNotEmpty && searchQuery.length < 3)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Text('Type at least 3 chars...', style: TextStyle(color: Colors.white38, fontStyle: FontStyle.italic)),
            ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, color: Colors.white),
            onPressed: onPrevMatch,
            tooltip: 'Previous match',
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
            onPressed: onNextMatch,
            tooltip: 'Next match',
          ),
          Container(width: 1, height: 24, color: Colors.white24, margin: const EdgeInsets.symmetric(horizontal: 8)),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: onClose,
            tooltip: 'Close search',
          ),
        ],
      ),
    );
  }
}