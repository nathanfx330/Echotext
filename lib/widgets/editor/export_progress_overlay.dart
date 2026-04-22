import 'package:flutter/material.dart';

class ExportProgressOverlay extends StatelessWidget {
  final bool isSaving;
  final double saveProgress;
  final String saveEta;

  const ExportProgressOverlay({
    super.key,
    required this.isSaving,
    required this.saveProgress,
    required this.saveEta,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
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
            if (isSaving) ...[
              LinearProgressIndicator(
                value: saveProgress, 
                backgroundColor: Colors.white10, 
                color: Colors.blueGrey,
              ),
              const SizedBox(height: 8),
              Text(
                saveEta, 
                style: const TextStyle(
                  color: Colors.white54, 
                  fontSize: 13, 
                  fontWeight: FontWeight.bold,
                ),
              ),
            ] else ...[
              const LinearProgressIndicator(
                backgroundColor: Colors.white10, 
                color: Colors.blueGrey,
              ),
            ]
          ],
        ),
      ),
    );
  }
}