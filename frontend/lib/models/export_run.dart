class ExportedItem {
  final String title;
  final String externalUrl;
  final String error;

  const ExportedItem({required this.title, this.externalUrl = '', this.error = ''});

  bool get succeeded => error.isEmpty;

  factory ExportedItem.fromJson(Map<String, dynamic> json) => ExportedItem(
        title: json['title'] as String? ?? '',
        externalUrl: json['external_url'] as String? ?? '',
        error: json['error'] as String? ?? '',
      );
}

class ExportRun {
  final String id;
  final String provider;
  final String createdAt;
  final List<ExportedItem> items;

  const ExportRun({
    required this.id,
    required this.provider,
    required this.createdAt,
    this.items = const [],
  });

  factory ExportRun.fromJson(Map<String, dynamic> json) => ExportRun(
        id: json['id'] as String,
        provider: json['provider'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        items: (json['items'] as List<dynamic>?)
                ?.map((i) => ExportedItem.fromJson(i as Map<String, dynamic>))
                .toList() ??
            [],
      );
}
