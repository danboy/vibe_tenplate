class Goal {
  final String id;
  final String teamId;
  final String title;
  final String unit;
  final double targetValue;
  final double currentValue;
  final List<KeyResult> keyResults;

  const Goal({
    required this.id,
    required this.teamId,
    required this.title,
    this.unit = '',
    this.targetValue = 0,
    this.currentValue = 0,
    this.keyResults = const [],
  });

  bool get isOkr => keyResults.isNotEmpty;

  factory Goal.fromJson(Map<String, dynamic> json) => Goal(
        id: json['id'] as String,
        teamId: json['team_id'] as String,
        title: json['title'] as String,
        unit: json['unit'] as String? ?? '',
        targetValue: (json['target_value'] as num?)?.toDouble() ?? 0,
        currentValue: (json['current_value'] as num?)?.toDouble() ?? 0,
        keyResults: (json['key_results'] as List<dynamic>?)
                ?.map((k) => KeyResult.fromJson(k as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

class KeyResult {
  final String id;
  final String goalId;
  final String title;
  final String unit;
  final double targetValue;
  final double currentValue;

  const KeyResult({
    required this.id,
    required this.goalId,
    required this.title,
    this.unit = '',
    this.targetValue = 0,
    this.currentValue = 0,
  });

  factory KeyResult.fromJson(Map<String, dynamic> json) => KeyResult(
        id: json['id'] as String,
        goalId: json['goal_id'] as String,
        title: json['title'] as String,
        unit: json['unit'] as String? ?? '',
        targetValue: (json['target_value'] as num?)?.toDouble() ?? 0,
        currentValue: (json['current_value'] as num?)?.toDouble() ?? 0,
      );
}
