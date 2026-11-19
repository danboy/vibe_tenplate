import 'dart:html' as html;

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
  String? _exportingDataFormat;
  String? _dataExportError;

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

  Future<void> _downloadData(String format) async {
    if (_exportingDataFormat != null) return;
    setState(() {
      _exportingDataFormat = format;
      _dataExportError = null;
    });
    try {
      final api = context.read<AuthProvider>().api;
      final bytes = await api.exportBrainstormData(
        groupSlug: widget.groupSlug,
        brainstormSlug: widget.brainstormSlug,
        format: format,
      );
      final mimeType = format == 'csv' ? 'text/csv' : 'application/json';
      final blob = html.Blob([bytes], mimeType);
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute('download', 'brainstorm-${widget.brainstormSlug}-export.$format')
        ..click();
      html.Url.revokeObjectUrl(url);
    } catch (e) {
      if (mounted) setState(() => _dataExportError = e.toString());
    } finally {
      if (mounted) setState(() => _exportingDataFormat = null);
    }
  }

  Widget _buildDataExportSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Export data', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'Cards placed on the prioritize matrix, with their coordinates, '
          'quadrant, and vote count — ranked by position within each quadrant.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _exportingDataFormat != null ? null : () => _downloadData('json'),
              icon: _exportingDataFormat == 'json'
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              label: const Text('Download JSON'),
            ),
            OutlinedButton.icon(
              onPressed: _exportingDataFormat != null ? null : () => _downloadData('csv'),
              icon: _exportingDataFormat == 'csv'
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              label: const Text('Download CSV'),
            ),
          ],
        ),
        if (_dataExportError != null) ...[
          const SizedBox(height: 12),
          Text(_dataExportError!, style: const TextStyle(color: Colors.red)),
        ],
      ],
    );
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
          if (connected.isNotEmpty) {
            _selectedProvider ??= connected.first.provider;
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildDataExportSection(),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 24),
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
              if (connected.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.link_off, size: 24, color: Colors.grey),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'This group\'s team hasn\'t connected GitHub or Asana yet, '
                          'or hasn\'t set a target repo/project. Ask the team owner to '
                          'connect one in team settings.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
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
