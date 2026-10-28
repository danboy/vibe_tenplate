import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/team_integration.dart';

const _providers = ['github', 'asana'];

const _providerLabels = {
  'github': 'GitHub',
  'asana': 'Asana',
};

const _targetHints = {
  'github': 'owner/repo',
  'asana': 'Asana project GID',
};

class TeamIntegrationsSection extends StatefulWidget {
  final String teamSlug;

  const TeamIntegrationsSection({super.key, required this.teamSlug});

  @override
  State<TeamIntegrationsSection> createState() => _TeamIntegrationsSectionState();
}

class _TeamIntegrationsSectionState extends State<TeamIntegrationsSection> {
  late Future<List<TeamIntegration>> _future;
  final _controllers = {for (final p in _providers) p: TextEditingController()};
  final _saving = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _load() {
    _future = context.read<AuthProvider>().api.listTeamIntegrations(widget.teamSlug).then((rows) {
      for (final row in rows) {
        _controllers[row.provider]?.text = row.targetRef;
      }
      return rows;
    });
  }

  void _refresh() => setState(_load);

  Future<void> _connect(String provider) async {
    final api = context.read<AuthProvider>().api;
    final uri = Uri.parse(api.integrationConnectUrl(widget.teamSlug, provider));
    await launchUrl(uri, webOnlyWindowName: '_self');
  }

  Future<void> _saveTarget(String provider) async {
    final targetRef = _controllers[provider]!.text.trim();
    if (targetRef.isEmpty) return;
    setState(() => _saving.add(provider));
    try {
      final api = context.read<AuthProvider>().api;
      await api.setIntegrationTargetRef(
        teamSlug: widget.teamSlug,
        provider: provider,
        targetRef: targetRef,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving.remove(provider));
    }
  }

  Future<void> _disconnect(String provider) async {
    setState(() => _saving.add(provider));
    try {
      final api = context.read<AuthProvider>().api;
      await api.disconnectIntegration(teamSlug: widget.teamSlug, provider: provider);
      _controllers[provider]?.clear();
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving.remove(provider));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<TeamIntegration>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          );
        }
        final connected = {for (final r in snap.data ?? <TeamIntegration>[]) r.provider: r};

        return Column(
          children: [
            for (final provider in _providers) ...[
              if (connected.containsKey(provider)) ...[
                Row(
                  children: [
                    Icon(Icons.check_circle, size: 16, color: Colors.green.shade600),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Connected to ${_providerLabels[provider]}'
                        '${connected[provider]!.accountLabel.isNotEmpty ? ' as ${connected[provider]!.accountLabel}' : ''}',
                      ),
                    ),
                    TextButton(
                      onPressed: _saving.contains(provider) ? null : () => _disconnect(provider),
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controllers[provider],
                        decoration: InputDecoration(
                          labelText: _targetHints[provider],
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Save',
                      icon: _saving.contains(provider)
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.check),
                      onPressed:
                          _saving.contains(provider) ? null : () => _saveTarget(provider),
                    ),
                  ],
                ),
              ] else
                OutlinedButton.icon(
                  onPressed: () => _connect(provider),
                  icon: const Icon(Icons.link, size: 18),
                  label: Text('Connect ${_providerLabels[provider]}'),
                ),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }
}
