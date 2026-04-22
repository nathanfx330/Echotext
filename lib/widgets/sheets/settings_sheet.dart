import 'package:flutter/material.dart';
import '../../models/voice_model.dart';

class SettingsSheet extends StatelessWidget {
  final VoiceModel? selectedVoice;
  final List<VoiceModel> availableVoices;
  final double speechSpeed;
  final int speakerId;
  final Function(VoiceModel) onVoiceSelected;
  final Function(double) onSpeedChanged;
  final Function(int) onSpeakerIdChanged;
  final VoidCallback onPickCustomModel;

  const SettingsSheet({
    super.key,
    required this.selectedVoice,
    required this.availableVoices,
    required this.speechSpeed,
    required this.speakerId,
    required this.onVoiceSelected,
    required this.onSpeedChanged,
    required this.onSpeakerIdChanged,
    required this.onPickCustomModel,
  });

  @override
  Widget build(BuildContext context) {
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
                      value: selectedVoice,
                      dropdownColor: const Color(0xFF2C2C2C),
                      hint: const Text('No voices found in model/ folder'),
                      items: availableVoices.map((voice) {
                        return DropdownMenuItem<VoiceModel>(
                          value: voice,
                          child: Text(voice.name, overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (VoiceModel? newVoice) {
                        if (newVoice != null) {
                          onVoiceSelected(newVoice);
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
                  onPressed: onPickCustomModel,
                ),
              )
            ],
          ),
          const Divider(height: 32, color: Colors.white12),
          
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Speed (Length Scale):', style: TextStyle(color: Colors.white70)),
              Text('${speechSpeed.toStringAsFixed(2)}x'),
            ],
          ),
          Slider(
            value: speechSpeed,
            min: 0.5, max: 2.0, divisions: 15,
            label: speechSpeed.toStringAsFixed(2),
            onChanged: onSpeedChanged,
          ),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Speaker ID (Multispeaker):', style: TextStyle(color: Colors.white70)),
              Text(speakerId.toString()),
            ],
          ),
          Slider(
            value: speakerId.toDouble(),
            min: 0, max: 50, divisions: 50,
            label: speakerId.toString(),
            onChanged: (val) => onSpeakerIdChanged(val.toInt()),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}