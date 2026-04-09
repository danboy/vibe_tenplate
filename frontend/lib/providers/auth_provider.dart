import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  String? _token;
  User? _user;
  bool _isLoading = true;
  String? _pendingPlan;
  String? _currentTeamSlug;

  bool get isAuthenticated => _token != null && _user != null;
  bool get isLoading => _isLoading;
  User? get user => _user;
  String? get token => _token;
  String? get pendingPlan => _pendingPlan;
  String? get currentTeamSlug => _currentTeamSlug;

  void clearPendingPlan() => _pendingPlan = null;

  ApiService get api => ApiService(token: _token);

  Future<void> setCurrentTeam(String slug) async {
    if (_currentTeamSlug == slug) return;
    _currentTeamSlug = slug;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_team_slug', slug);
    notifyListeners();
  }

  Future<void> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('auth_token');
    _currentTeamSlug = prefs.getString('current_team_slug');
    if (_token != null) {
      try {
        _user = await ApiService(token: _token).getMe();
      } catch (_) {
        _token = null;
        await prefs.remove('auth_token');
      }
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> register({
    required String username,
    required String email,
    required String password,
    String? plan,
  }) async {
    final result = await ApiService().register(
      username: username,
      email: email,
      password: password,
    );
    if (plan != null && plan != 'free') _pendingPlan = plan;
    await _saveSession(result.token, result.user);
  }

  Future<void> login({
    required String email,
    required String password,
  }) async {
    final result = await ApiService().login(email: email, password: password);
    await _saveSession(result.token, result.user);
  }

  Future<void> _saveSession(String token, User user) async {
    _token = token;
    _user = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    notifyListeners();
  }

  Future<void> logout() async {
    _token = null;
    _user = null;
    _currentTeamSlug = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('current_team_slug');
    notifyListeners();
  }
}
