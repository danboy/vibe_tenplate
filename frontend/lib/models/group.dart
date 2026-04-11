class Group {
  final String id;
  final String slug;
  final String name;
  final String description;
  final String ownerId;
  final int memberCount;
  final bool isMember;
  final String plan;
  final String myTeamRole; // "owner", "editor", "member", or ""
  final List<GroupMember> members;

  const Group({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.ownerId,
    this.memberCount = 0,
    this.isMember = false,
    this.plan = 'free',
    this.myTeamRole = '',
    this.members = const [],
  });

  bool get canCreate => myTeamRole == 'owner' || myTeamRole == 'editor';

  factory Group.fromJson(Map<String, dynamic> json) => Group(
        id: json['id'] as String,
        slug: json['slug'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        ownerId: json['owner_id'] as String,
        memberCount: json['member_count'] as int? ?? 0,
        isMember: json['is_member'] as bool? ?? false,
        plan: json['plan'] as String? ?? 'free',
        myTeamRole: json['my_team_role'] as String? ?? '',
        members: (json['members'] as List<dynamic>?)
                ?.map((m) => GroupMember.fromJson(m as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

class GroupMember {
  final String id;
  final String username;
  final String email;

  const GroupMember({
    required this.id,
    required this.username,
    required this.email,
  });

  factory GroupMember.fromJson(Map<String, dynamic> json) => GroupMember(
        id: json['id'] as String,
        username: json['username'] as String,
        email: json['email'] as String,
      );
}
