class TeamIntegration {
  final String provider;
  final String accountLabel;
  final String targetRef;

  const TeamIntegration({
    required this.provider,
    this.accountLabel = '',
    this.targetRef = '',
  });

  factory TeamIntegration.fromJson(Map<String, dynamic> json) => TeamIntegration(
        provider: json['provider'] as String,
        accountLabel: json['account_label'] as String? ?? '',
        targetRef: json['target_ref'] as String? ?? '',
      );
}
