class StickyNote {
  final String id;
  final String content;
  final double posX;
  final double posY;
  final String color;
  final String author;
  final String createdBy;
  final String? parentId;
  final bool isGroup;
  final double? matrixCost;
  final double? matrixValue;

  const StickyNote({
    required this.id,
    required this.content,
    required this.posX,
    required this.posY,
    required this.color,
    required this.author,
    required this.createdBy,
    this.parentId,
    this.isGroup = false,
    this.matrixCost,
    this.matrixValue,
  });

  factory StickyNote.fromJson(Map<String, dynamic> json) => StickyNote(
        id: json['id'] as String,
        content: json['content'] as String? ?? '',
        posX: (json['pos_x'] as num).toDouble(),
        posY: (json['pos_y'] as num).toDouble(),
        color: json['color'] as String? ?? '#FFF176',
        author: json['author'] as String? ?? '',
        createdBy: json['created_by'] as String? ?? '',
        parentId: json['parent_id'] as String?,
        isGroup: json['is_group'] as bool? ?? false,
        matrixCost: (json['matrix_cost'] as num?)?.toDouble(),
        matrixValue: (json['matrix_value'] as num?)?.toDouble(),
      );

  StickyNote copyWith({
    String? content,
    double? posX,
    double? posY,
    String? parentId,
    bool clearParent = false,
  }) =>
      StickyNote(
        id: id,
        content: content ?? this.content,
        posX: posX ?? this.posX,
        posY: posY ?? this.posY,
        color: color,
        author: author,
        createdBy: createdBy,
        parentId: clearParent ? null : (parentId ?? this.parentId),
        isGroup: isGroup,
      );
}
