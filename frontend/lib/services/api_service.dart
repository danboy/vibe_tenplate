import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import '../models/user.dart';
import '../models/group.dart';
import '../models/project.dart';

class ApiException implements Exception {
  final String message;
  final int statusCode;

  const ApiException(this.message, this.statusCode);

  @override
  String toString() => message;
}

class ApiService {
  static String get baseUrl =>
      dotenv.get('BASE_URL', fallback: 'http://localhost:8080/api');
  static String get wsBaseUrl =>
      dotenv.get('WS_BASE_URL', fallback: 'ws://localhost:8080');

  static const _timeout = Duration(seconds: 15);

  final String? token;

  const ApiService({this.token});

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<http.Response> _get(Uri url) =>
      http.get(url, headers: _headers).timeout(_timeout);

  Future<http.Response> _post(Uri url, {String? body}) =>
      http.post(url, headers: _headers, body: body).timeout(_timeout);

  Future<http.Response> _put(Uri url, {String? body}) =>
      http.put(url, headers: _headers, body: body).timeout(_timeout);

  Future<http.Response> _patch(Uri url, {String? body}) =>
      http.patch(url, headers: _headers, body: body).timeout(_timeout);

  Future<http.Response> _delete(Uri url) =>
      http.delete(url, headers: _headers).timeout(_timeout);

  Future<Map<String, dynamic>> _parseMap(http.Response response) {
    Map<String, dynamic> body;
    try {
      body = json.decode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw ApiException(
          'Server error (${response.statusCode})', response.statusCode);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return Future.value(body);
    }
    throw ApiException(
      body['error'] as String? ?? 'Unknown error',
      response.statusCode,
    );
  }

  Future<List<dynamic>> _parseList(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return Future.value(json.decode(response.body) as List<dynamic>);
    }
    String message;
    try {
      final body = json.decode(response.body) as Map<String, dynamic>;
      message = body['error'] as String? ?? 'Unknown error';
    } on FormatException {
      message = 'Server error (${response.statusCode})';
    }
    throw ApiException(message, response.statusCode);
  }

  // ── Auth ────────────────────────────────────────────────────────────────────

  Future<({String token, User user})> register({
    required String username,
    required String email,
    required String password,
  }) async {
    final response = await _post(
      Uri.parse('$baseUrl/auth/register'),
      body: json.encode({
        'username': username,
        'email': email,
        'password': password,
      }),
    );
    final data = await _parseMap(response);
    return (
      token: data['token'] as String,
      user: User.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  Future<({String token, User user})> login({
    required String email,
    required String password,
  }) async {
    final response = await _post(
      Uri.parse('$baseUrl/auth/login'),
      body: json.encode({'email': email, 'password': password}),
    );
    final data = await _parseMap(response);
    return (
      token: data['token'] as String,
      user: User.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  Future<User> getMe() async {
    final response = await _get(Uri.parse('$baseUrl/users/me'));
    final data = await _parseMap(response);
    return User.fromJson(data);
  }


  // ── Guest ───────────────────────────────────────────────────────────────────

  /// Fetches minimal project info without auth — used to check if guests are enabled.
  Future<Map<String, dynamic>> getGuestProject(String groupSlug, String projectSlug) async {
    final response = await _get(
      Uri.parse('$baseUrl/guest/groups/$groupSlug/projects/$projectSlug'),
    );
    return _parseMap(response);
  }

  /// Joins a project as a guest and returns a short-lived token.
  Future<String> guestJoin(String projectId, String displayName) async {
    final response = await _post(
      Uri.parse('$baseUrl/guest/projects/$projectId/join'),
      body: json.encode({'display_name': displayName}),
    );
    final data = await _parseMap(response);
    return data['token'] as String;
  }

  // ── Groups ──────────────────────────────────────────────────────────────────

  Future<List<Group>> listGroups() async {
    final response = await _get(Uri.parse('$baseUrl/groups'));
    final list = await _parseList(response);
    return list.map((g) => Group.fromJson(g as Map<String, dynamic>)).toList();
  }

  Future<Group> getGroup(String slug) async {
    final response = await _get(Uri.parse('$baseUrl/groups/$slug'));
    final data = await _parseMap(response);
    return Group.fromJson(data);
  }

  Future<Group> createGroup({
    required String name,
    required String description,
    bool isPrivate = false,
  }) async {
    final response = await _post(
      Uri.parse('$baseUrl/groups'),
      body: json.encode({
        'name': name,
        'description': description,
        'is_private': isPrivate,
      }),
    );
    final data = await _parseMap(response);
    return Group.fromJson(data);
  }

  Future<({String slug, String name})> joinByCode(String code) async {
    final response = await _post(
      Uri.parse('$baseUrl/groups/join-by-code'),
      body: json.encode({'code': code}),
    );
    final data = await _parseMap(response);
    return (slug: data['slug'] as String, name: data['name'] as String);
  }

  Future<void> joinGroup(String slug, {String? code}) async {
    final response = await _post(
      Uri.parse('$baseUrl/groups/$slug/join'),
      body: code != null ? json.encode({'code': code}) : null,
    );
    await _parseMap(response);
  }

  Future<Group> updateGroupPlan(String groupSlug, String plan) async {
    final response = await _patch(
      Uri.parse('$baseUrl/groups/$groupSlug/plan'),
      body: json.encode({'plan': plan}),
    );
    final data = await _parseMap(response);
    return Group.fromJson(data);
  }

  Future<void> leaveGroup(String slug) async {
    final response = await _post(Uri.parse('$baseUrl/groups/$slug/leave'));
    await _parseMap(response);
  }

  Future<List<Group>> getMyGroups() async {
    final response = await _get(Uri.parse('$baseUrl/users/me/groups'));
    final list = await _parseList(response);
    return list.map((g) => Group.fromJson(g as Map<String, dynamic>)).toList();
  }

  // ── Projects ────────────────────────────────────────────────────────────────

  Future<List<Project>> listProjects(String groupSlug) async {
    final response = await _get(Uri.parse('$baseUrl/groups/$groupSlug/projects'));
    final list = await _parseList(response);
    return list
        .map((p) => Project.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  Future<Project> getProject({
    required String groupSlug,
    required String projectSlug,
  }) async {
    final response = await _get(
      Uri.parse('$baseUrl/groups/$groupSlug/projects/$projectSlug'),
    );
    final data = await _parseMap(response);
    return Project.fromJson(data);
  }

  Future<Project> createProject({
    required String groupSlug,
    required String name,
    required String description,
    required String problemStatement,
    required bool enableProblem,
    required bool enableVote,
    required bool enablePrioritise,
    bool guestsEnabled = false,
    String interstitialProblem = '',
    String interstitialBrainstorm = '',
    String interstitialGroup = '',
    String interstitialVote = '',
    String interstitialPrioritise = '',
  }) async {
    final response = await _post(
      Uri.parse('$baseUrl/groups/$groupSlug/projects'),
      body: json.encode({
        'name': name,
        'description': description,
        'problem_statement': problemStatement,
        'enable_problem': enableProblem,
        'enable_vote': enableVote,
        'enable_prioritise': enablePrioritise,
        'guests_enabled': guestsEnabled,
        'interstitial_problem': interstitialProblem,
        'interstitial_brainstorm': interstitialBrainstorm,
        'interstitial_group': interstitialGroup,
        'interstitial_vote': interstitialVote,
        'interstitial_prioritise': interstitialPrioritise,
      }),
    );
    final data = await _parseMap(response);
    return Project.fromJson(data);
  }

  Future<Project> updateProject({
    required String groupSlug,
    required String projectSlug,
    required String name,
    required String description,
    required String problemStatement,
    required bool enableProblem,
    required bool enableVote,
    required bool enablePrioritise,
    bool guestsEnabled = false,
    String interstitialProblem = '',
    String interstitialBrainstorm = '',
    String interstitialGroup = '',
    String interstitialVote = '',
    String interstitialPrioritise = '',
  }) async {
    final response = await _patch(
      Uri.parse('$baseUrl/groups/$groupSlug/projects/$projectSlug'),
      body: json.encode({
        'name': name,
        'description': description,
        'problem_statement': problemStatement,
        'enable_problem': enableProblem,
        'enable_vote': enableVote,
        'enable_prioritise': enablePrioritise,
        'guests_enabled': guestsEnabled,
        'interstitial_problem': interstitialProblem,
        'interstitial_brainstorm': interstitialBrainstorm,
        'interstitial_group': interstitialGroup,
        'interstitial_vote': interstitialVote,
        'interstitial_prioritise': interstitialPrioritise,
      }),
    );
    final data = await _parseMap(response);
    return Project.fromJson(data);
  }

  Future<void> deleteProject({
    required String groupSlug,
    required String projectSlug,
  }) async {
    final response = await _delete(
      Uri.parse('$baseUrl/groups/$groupSlug/projects/$projectSlug'),
    );
    await _parseMap(response);
  }

  Future<Project> setPresenter({
    required String groupSlug,
    required String projectSlug,
    String? userId,
  }) async {
    final response = await _put(
      Uri.parse('$baseUrl/groups/$groupSlug/projects/$projectSlug/presenter'),
      body: json.encode({'user_id': userId}),
    );
    final data = await _parseMap(response);
    return Project.fromJson(data);
  }
}
