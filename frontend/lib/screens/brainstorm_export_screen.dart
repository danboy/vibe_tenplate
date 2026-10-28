import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/export_run.dart';
import '../models/team_integration.dart';

const _providerLabels = {
  'github': 'GitHub',
  'asana': 'Asana',
};

class BrainstormExportScreen extends StatefulWidget {
  final String groupSlug;
  final String brainstormSlug;

  const BrainstormExportScreen({
    super.key,
    required this.groupSlug,
    required this.brainstormSlug,
  });

  @override
  State<BrainstormExportScreen> createState() => _BrainstormExportScreenState();
}

class _BrainstormExportScreenState extends State<BrainstormExportScreen> {
  late Future<_ExportPageData> _future;
  String? _selectedProvider;
  bool _exporting = false;
  String? _exportError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final api = context.read<AuthProvider>().api;
    _future = Future.wait([
      api.listGroupIntegrations(widget.groupSlug).catchError((_) => <TeamIntegration>[]),
      api.listExportRuns(groupSlug: widget.groupSlug, brainstormSlug: widget.brainstormSlug),
    ]).then((results) {
      final integrations = results[0] as List<TeamIntegration>;
      final runs = results[1] as List<ExportRun>;
      return _ExportPageData(integrations: integrations, runs: runs);
    });
  }

  Future<void> _export() async {
    if (_selectedProvider == null || _exporting) return;
    setState(() {
      _exporting = true;
      _exportError = null;
    });
    try {
      final api = context.read<AuthProvider>().api;
      await api.exportBrainstorm(
        groupSlug: widget.groupSlug,
        brainstormSlug: widget.brainstormSlug,
        provider: _selectedProvider!,
      );
      if (mounted) setState(_load);
    } catch (e) {
      if (mounted) setState(() => _exportError = e.toString());
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('Export'),
      ),
      body: FutureBuilder<_ExportPageData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text(snap.error.toString()));
          }

          final data = snap.data!;
          final connected = data.integrations.where((i) => i.targetRef.isNotEmpty).toList();

          if (connected.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.link_off, size: 40, color: Colors.grey),
                    SizedBox(height: 12),
                    Text(
                      'This group\'s team hasn\'t connected GitHub or Asana yet, '
                      'or hasn\'t set a target repo/project.',
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Ask the team owner to connect one in team settings.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            );
          }

          _selectedProvider ??= connected.first.provider;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Export this brainstorm\'s note groups',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(
                'Each group of notes becomes one issue/task; ungrouped notes '
                'become their own. Re-running this creates new issues/tasks — '
                'it does not update ones already created.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 16),
              if (connected.length > 1)
                Wrap(
                  spacing: 8,
                  children: connected
                      .map((i) => ChoiceChip(
                            label: Text(_providerLabels[i.provider] ?? i.provider),
                            selected: _selectedProvider == i.provider,
                            onSelected: (_) => setState(() => _selectedProvider = i.provider),
                          ))
                      .toList(),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _exporting ? null : _export,
                icon: _exporting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.ios_share),
                label: Text('Export to ${_providerLabels[_selectedProvider] ?? _selectedProvider}'),
              ),
              if (_exportError != null) ...[
                const SizedBox(height: 12),
                Text(_exportError!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 24),
              if (data.runs.isNotEmpty) ...[
                Text('History', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ...data.runs.map((run) => _ExportRunCard(run: run)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ExportPageData {
  final List<TeamIntegration> integrations;
  final List<ExportRun> runs;

  const _ExportPageData({required this.integrations, required this.runs});
}

class _ExportRunCard extends StatelessWidget {
  final ExportRun run;

  const _ExportRunCard({required this.run});

  @override
  Widget build(BuildContext context) {
    final succeeded = run.items.where((i) => i.succeeded).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_providerLabels[run.provider] ?? run.provider} — '
              '$succeeded/${run.items.length} created',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            ...run.items.map((item) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      Icon(
                        item.succeeded ? Icons.check_circle_outline : Icons.error_outline,
                        size: 14,
                        color: item.succeeded ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          item.succeeded ? item.title : '${item.title} — ${item.error}',
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
