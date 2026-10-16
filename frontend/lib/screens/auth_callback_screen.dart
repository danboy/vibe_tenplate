import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_banner.dart';

class AuthCallbackScreen extends StatefulWidget {
  final String? token;
  final String? redirect;

  const AuthCallbackScreen({super.key, this.token, this.redirect});

  @override
  State<AuthCallbackScreen> createState() => _AuthCallbackScreenState();
}

class _AuthCallbackScreenState extends State<AuthCallbackScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _complete();
  }

  Future<void> _complete() async {
    final token = widget.token;
    if (token == null || token.isEmpty) {
      setState(() => _error = 'Missing SSO token');
      return;
    }
    try {
      await context.read<AuthProvider>().loginWithToken(token);
      if (!mounted) return;
      final dest = widget.redirect;
      context.go(dest != null && dest.startsWith('/') ? dest : '/teams');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: ErrorBanner(message: _error!),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
