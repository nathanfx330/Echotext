class VoiceModel {
  final String name;
  final String path;

  VoiceModel({required this.name, required this.path});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is VoiceModel && other.path == path;

  @override
  int get hashCode => path.hashCode;
}