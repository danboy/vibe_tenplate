import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

const _providerLabels = {
  'github': 'GitHub',
  'asana': 'Asana',
};

/// Reached after the backend finishes a team-integration OAuth flow
/// (`handlers.IntegrationHandler.Callback`). Unlike `AuthCallbackScreen`,
/// no token is handled here — the backend already stored it server-side
/// against the team — this screen just confirms success.
class IntegrationCallbackScreen extends StatelessWidget {
  final String? connected;

  const IntegrationCallbackScreen({super.key, this.connected});

  @override
  Widget build(BuildContext context) {
    final label = _providerLabels[connected] ?? connected ?? 'the integration';
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, size: 48, color: Colors.green.shade600),
              const SizedBox(height: 16),
              Text('Connected to $label',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => context.go('/teams'),
                child: const Text('Back to teams'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
