class Brainstorm {
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
  final String type;
  final String retroStyle;
  final bool enableProblem;
  final bool enableVote;
  final bool enablePrioritise;
  final bool guestsEnabled;
  final bool timerEnabled;
  final int timerMinutes;
  final String problemStatement;
  final int activeUsers;
  final String interstitialProblem;
  final String interstitialBrainstorm;
  final String interstitialGroup;
  final String interstitialVote;
  final String interstitialPrioritise;
  final String interstitialActionItems;

  const Brainstorm({
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
    this.type = 'brainstorm',
    this.retroStyle = '',
    this.enableProblem = true,
    this.enableVote = true,
    this.enablePrioritise = true,
    this.guestsEnabled = false,
    this.timerEnabled = false,
    this.timerMinutes = 5,
    this.problemStatement = '',
    this.activeUsers = 0,
    this.interstitialProblem = '',
    this.interstitialBrainstorm = '',
    this.interstitialGroup = '',
    this.interstitialVote = '',
    this.interstitialPrioritise = '',
    this.interstitialActionItems = '',
  });

  /// Returns the custom interstitial description for [slide], or null to use
  /// the app default.
  String? interstitialForSlide(int slide) {
    final value = switch (slide) {
      0 => interstitialProblem,
      1 => interstitialBrainstorm,
      2 => interstitialGroup,
      3 => interstitialVote,
      4 => isRetro ? interstitialActionItems : interstitialPrioritise,
      _ => '',
    };
    return value.isEmpty ? null : value;
  }

  bool get isCardSort => type == 'card_sort';
  bool get isRetro => type == 'retro';

  factory Brainstorm.fromJson(Map<String, dynamic> json) => Brainstorm(
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
        type: json['type'] as String? ?? 'brainstorm',
        retroStyle: json['retro_style'] as String? ?? '',
        enableProblem: json['enable_problem'] as bool? ?? true,
        enableVote: json['enable_vote'] as bool? ?? true,
        enablePrioritise: json['enable_prioritise'] as bool? ?? true,
        guestsEnabled: json['guests_enabled'] as bool? ?? false,
        timerEnabled: json['timer_enabled'] as bool? ?? false,
        timerMinutes: json['timer_minutes'] as int? ?? 5,
        problemStatement: json['problem_statement'] as String? ?? '',
        activeUsers: json['active_users'] as int? ?? 0,
        interstitialProblem: json['interstitial_problem'] as String? ?? '',
        interstitialBrainstorm: json['interstitial_brainstorm'] as String? ?? '',
        interstitialGroup: json['interstitial_group'] as String? ?? '',
        interstitialVote: json['interstitial_vote'] as String? ?? '',
        interstitialPrioritise: json['interstitial_prioritise'] as String? ?? '',
        interstitialActionItems: json['interstitial_action_items'] as String? ?? '',
      );

  Brainstorm copyWith({String? presenterId, String? presenterUsername, bool clearPresenter = false}) =>
      Brainstorm(
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
        type: type,
        retroStyle: retroStyle,
        enableProblem: enableProblem,
        enableVote: enableVote,
        enablePrioritise: enablePrioritise,
        timerEnabled: timerEnabled,
        timerMinutes: timerMinutes,
      );
}
