class Team {
  final String id;
  final String slug;
  final String name;
  final String description;
  final String ownerId;
  final String plan;
  final bool isPrivate;
  final String? joinCode;
  final int memberCount;
  final bool isMember;
  final List<TeamMember> members;

  const Team({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.ownerId,
    this.plan = 'free',
    this.isPrivate = false,
    this.joinCode,
    this.memberCount = 0,
    this.isMember = false,
    this.members = const [],
  });

  factory Team.fromJson(Map<String, dynamic> json) => Team(
        id: json['id'] as String,
        slug: json['slug'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        ownerId: json['owner_id'] as String,
        plan: json['plan'] as String? ?? 'free',
        isPrivate: json['is_private'] as bool? ?? false,
        joinCode: json['join_code'] as String?,
        memberCount: json['member_count'] as int? ?? 0,
        isMember: json['is_member'] as bool? ?? false,
        members: (json['members'] as List<dynamic>?)
                ?.map((m) => TeamMember.fromJson(m as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

class TeamMember {
  final String id;
  final String username;
  final String email;

  const TeamMember({
    required this.id,
    required this.username,
    required this.email,
  });

  factory TeamMember.fromJson(Map<String, dynamic> json) => TeamMember(
        id: json['id'] as String,
        username: json['username'] as String,
        email: json['email'] as String,
      );
}
