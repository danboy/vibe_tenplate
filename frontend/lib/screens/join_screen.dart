import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class JoinScreen extends StatefulWidget {
  final String code;

  const JoinScreen({super.key, required this.code});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  bool _loading = true;
  String? _error;
  String? _groupName;

  @override
  void initState() {
    super.initState();
    _join();
  }

  Future<void> _join() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<AuthProvider>().api;
      final result = await api.joinByCode(widget.code);
      if (!mounted) return;
      setState(() => _groupName = result.name);
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) context.go('/groups/${result.slug}');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_loading) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  const Text('Joining group…',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                ] else if (_error != null) ...[
                  Icon(Icons.error_outline,
                      size: 56, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton(
                        onPressed: () => context.go('/groups'),
                        child: const Text('Go home'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _join,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ] else ...[
                  Icon(Icons.check_circle_outline,
                      size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'Joined ${_groupName ?? 'group'}!',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text('Taking you there…',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
