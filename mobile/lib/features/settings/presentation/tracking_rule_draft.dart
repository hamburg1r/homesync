class TrackingRuleDraft {
  const TrackingRuleDraft({
    required this.name,
    required this.patternOrUri,
    this.tags = const [],
    this.sourceKind,
    this.bindToServer = false,
  });

  final String name;
  final String patternOrUri;
  final List<String> tags;
  final String? sourceKind;
  final bool bindToServer;
}
