class ActionItem {
  final String id;
  final String brainstormId;
  final String content;
  final String createdBy;
  final String author;

  const ActionItem({
    required this.id,
    required this.brainstormId,
    required this.content,
    required this.createdBy,
    required this.author,
  });

  ActionItem copyWith({String? content}) => ActionItem(
        id: id,
        brainstormId: brainstormId,
        content: content ?? this.content,
        createdBy: createdBy,
        author: author,
      );

  factory ActionItem.fromJson(Map<String, dynamic> json) => ActionItem(
        id: json['id'] as String,
        brainstormId: json['brainstorm_id'] as String,
        content: json['content'] as String? ?? '',
        createdBy: json['created_by'] as String? ?? '',
        author: json['author'] as String? ?? '',
      );
}
