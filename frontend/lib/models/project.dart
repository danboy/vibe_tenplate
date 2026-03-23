class Project {
  final String id;
  final String slug;
  final String name;
  final String description;
  final String groupId;
  final String createdBy;
  final String? creatorUsername;
  final DateTime createdAt;
  final String? presenterId;
  final String? presenterUsername;
  final bool enableVote;
  final bool enablePrioritise;

  const Project({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.groupId,
    required this.createdBy,
    this.creatorUsername,
    required this.createdAt,
    this.presenterId,
    this.presenterUsername,
    this.enableVote = true,
    this.enablePrioritise = true,
  });

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] as String,
        slug: json['slug'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        groupId: json['group_id'] as String,
        createdBy: json['created_by'] as String,
        creatorUsername:
            (json['creator'] as Map<String, dynamic>?)?['username'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        presenterId: json['presenter_id'] as String?,
        presenterUsername:
            (json['presenter'] as Map<String, dynamic>?)?['username'] as String?,
        enableVote: json['enable_vote'] as bool? ?? true,
        enablePrioritise: json['enable_prioritise'] as bool? ?? true,
      );

  Project copyWith({String? presenterId, String? presenterUsername, bool clearPresenter = false}) =>
      Project(
        id: id,
        slug: slug,
        name: name,
        description: description,
        groupId: groupId,
        createdBy: createdBy,
        creatorUsername: creatorUsername,
        createdAt: createdAt,
        presenterId: clearPresenter ? null : (presenterId ?? this.presenterId),
        presenterUsername: clearPresenter ? null : (presenterUsername ?? this.presenterUsername),
        enableVote: enableVote,
        enablePrioritise: enablePrioritise,
      );
}
