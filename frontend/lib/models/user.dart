class User {
  final String id;
  final String username;
  final String email;
  final bool isAdmin;

  const User({
    required this.id,
    required this.username,
    required this.email,
    this.isAdmin = false,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        username: json['username'] as String,
        email: json['email'] as String,
        isAdmin: json['is_admin'] as bool? ?? false,
      );
}
