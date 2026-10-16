class TeamSsoConfig {
  final String provider; // "google", "github", "gitlab"
  final String orgMatch;

  const TeamSsoConfig({required this.provider, required this.orgMatch});

  factory TeamSsoConfig.fromJson(Map<String, dynamic> json) => TeamSsoConfig(
        provider: json['provider'] as String,
        orgMatch: json['org_match'] as String,
      );
}
