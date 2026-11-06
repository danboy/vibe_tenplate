class AdminUserSummary {
  final String id;
  final String username;
  final String email;
  final bool isAdmin;
  final DateTime createdAt;

  const AdminUserSummary({
    required this.id,
    required this.username,
    required this.email,
    required this.isAdmin,
    required this.createdAt,
  });

  factory AdminUserSummary.fromJson(Map<String, dynamic> json) => AdminUserSummary(
        id: json['id'] as String,
        username: json['username'] as String,
        email: json['email'] as String,
        isAdmin: json['is_admin'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class AdminGroupSummary {
  final String id;
  final String slug;
  final String name;
  final String? teamId;
  final String teamName;
  final String ownerId;
  final String ownerUsername;
  final int memberCount;
  final DateTime createdAt;

  const AdminGroupSummary({
    required this.id,
    required this.slug,
    required this.name,
    this.teamId,
    required this.teamName,
    required this.ownerId,
    required this.ownerUsername,
    required this.memberCount,
    required this.createdAt,
  });

  factory AdminGroupSummary.fromJson(Map<String, dynamic> json) => AdminGroupSummary(
        id: json['id'] as String,
        slug: json['slug'] as String,
        name: json['name'] as String,
        teamId: json['team_id'] as String?,
        teamName: json['team_name'] as String? ?? '',
        ownerId: json['owner_id'] as String? ?? '',
        ownerUsername: json['owner_username'] as String? ?? '',
        memberCount: json['member_count'] as int? ?? 0,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class AdminActivitySummary {
  final String id;
  final String slug;
  final String name;
  final String type;
  final String groupId;
  final String groupName;
  final String groupSlug;
  final String teamName;
  final String createdBy;
  final String creatorUsername;
  final DateTime createdAt;

  const AdminActivitySummary({
    required this.id,
    required this.slug,
    required this.name,
    required this.type,
    required this.groupId,
    required this.groupName,
    required this.groupSlug,
    required this.teamName,
    required this.createdBy,
    required this.creatorUsername,
    required this.createdAt,
  });

  factory AdminActivitySummary.fromJson(Map<String, dynamic> json) => AdminActivitySummary(
        id: json['id'] as String,
        slug: json['slug'] as String,
        name: json['name'] as String,
        type: json['type'] as String? ?? 'brainstorm',
        groupId: json['group_id'] as String? ?? '',
        groupName: json['group_name'] as String? ?? '',
        groupSlug: json['group_slug'] as String? ?? '',
        teamName: json['team_name'] as String? ?? '',
        createdBy: json['created_by'] as String? ?? '',
        creatorUsername: json['creator_username'] as String? ?? '',
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}
