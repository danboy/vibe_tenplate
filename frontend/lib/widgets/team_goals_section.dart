import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/goal.dart';
import '../models/team.dart';

class TeamGoalsSection extends StatefulWidget {
  final Team team;
  final bool isOwner;
  final bool canManage;
  final VoidCallback onGoalStyleChanged;

  const TeamGoalsSection({
    super.key,
    required this.team,
    required this.isOwner,
    required this.canManage,
    required this.onGoalStyleChanged,
  });

  @override
  State<TeamGoalsSection> createState() => _TeamGoalsSectionState();
}

class _TeamGoalsSectionState extends State<TeamGoalsSection> {
  late Future<List<Goal>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = context.read<AuthProvider>().api.listGoals(widget.team.slug);
  }

  void _refresh() => setState(_load);

  Future<void> _changeStyle(String style) async {
    if (style == widget.team.goalStyle) return;
    try {
      final api = context.read<AuthProvider>().api;
      await api.updateTeamGoalStyle(teamSlug: widget.team.slug, goalStyle: style);
      widget.onGoalStyleChanged();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _addGoal() async {
    if (widget.team.goalStyle == 'okr') {
      await _openOkrDialog();
    } else {
      await _openKpiDialog();
    }
  }

  Future<void> _openKpiDialog({Goal? existing}) async {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final unitCtrl = TextEditingController(text: existing?.unit ?? '');
    final targetCtrl =
        TextEditingController(text: existing != null ? '${existing.targetValue}' : '');
    final currentCtrl =
        TextEditingController(text: existing != null ? '${existing.currentValue}' : '0');
    final formKey = GlobalKey<FormState>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New KPI' : 'Edit KPI'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: 'Metric name'),
                validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: targetCtrl,
                      decoration: const InputDecoration(labelText: 'Target'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) =>
                          v == null || double.tryParse(v) == null ? 'Number' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: currentCtrl,
                      decoration: const InputDecoration(labelText: 'Current'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) =>
                          v == null || double.tryParse(v) == null ? 'Number' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: unitCtrl,
                decoration: const InputDecoration(labelText: 'Unit (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final api = context.read<AuthProvider>().api;
      if (existing == null) {
        await api.createGoal(
          teamSlug: widget.team.slug,
          title: titleCtrl.text.trim(),
          unit: unitCtrl.text.trim(),
          targetValue: double.parse(targetCtrl.text),
          currentValue: double.parse(currentCtrl.text),
        );
      } else {
        await api.updateGoal(
          goalId: existing.id,
          title: titleCtrl.text.trim(),
          unit: unitCtrl.text.trim(),
          targetValue: double.parse(targetCtrl.text),
          currentValue: double.parse(currentCtrl.text),
        );
      }
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _openOkrDialog() async {
    final titleCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final keyResults = <_KeyResultDraft>[_KeyResultDraft()];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('New Objective'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: titleCtrl,
                    decoration: const InputDecoration(labelText: 'Objective'),
                    validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                    autofocus: true,
                  ),
                  const SizedBox(height: 16),
                  const Text('Key results',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  for (var i = 0; i < keyResults.length; i++) ...[
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextFormField(
                            controller: keyResults[i].titleCtrl,
                            decoration: const InputDecoration(labelText: 'Key result'),
                            validator: (v) =>
                                v == null || v.isEmpty ? 'Required' : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            controller: keyResults[i].targetCtrl,
                            decoration: const InputDecoration(labelText: 'Target'),
                            keyboardType:
                                const TextInputType.numberWithOptions(decimal: true),
                            validator: (v) =>
                                v == null || double.tryParse(v) == null ? 'Num' : null,
                          ),
                        ),
                        if (keyResults.length > 1)
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setLocal(() => keyResults.removeAt(i)),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setLocal(() => keyResults.add(_KeyResultDraft())),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add key result'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final api = context.read<AuthProvider>().api;
      await api.createGoal(
        teamSlug: widget.team.slug,
        title: titleCtrl.text.trim(),
        keyResults: keyResults
            .map((k) => {
                  'title': k.titleCtrl.text.trim(),
                  'target_value': double.parse(k.targetCtrl.text),
                  'current_value': 0,
                })
            .toList(),
      );
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _deleteGoal(Goal goal) async {
    try {
      final api = context.read<AuthProvider>().api;
      await api.deleteGoal(goal.id);
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _editKeyResultProgress(KeyResult kr) async {
    final currentCtrl = TextEditingController(text: '${kr.currentValue}');
    final formKey = GlobalKey<FormState>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(kr.title),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: currentCtrl,
            decoration: InputDecoration(labelText: 'Current progress (/ ${kr.targetValue})'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: (v) => v == null || double.tryParse(v) == null ? 'Number' : null,
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final api = context.read<AuthProvider>().api;
      await api.updateKeyResult(
        keyResultId: kr.id,
        title: kr.title,
        unit: kr.unit,
        targetValue: kr.targetValue,
        currentValue: double.parse(currentCtrl.text),
      );
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.isOwner) ...[
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'kpi', label: Text('KPI')),
              ButtonSegment(value: 'okr', label: Text('OKR')),
            ],
            selected: {widget.team.goalStyle},
            onSelectionChanged: (s) => _changeStyle(s.first),
          ),
          const SizedBox(height: 4),
          Text(
            'Controls the form used when adding a new goal.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
        ],
        FutureBuilder<List<Goal>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              );
            }
            if (snap.hasError) {
              return Text(snap.error.toString());
            }
            final goals = snap.data ?? [];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (goals.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('No goals yet.',
                        style: TextStyle(color: Colors.grey.shade600)),
                  ),
                ...goals.map((g) => _GoalCard(
                      goal: g,
                      canManage: widget.canManage,
                      onDelete: () => _deleteGoal(g),
                      onEditKpi: () => _openKpiDialog(existing: g),
                      onEditKeyResult: _editKeyResultProgress,
                    )),
              ],
            );
          },
        ),
        if (widget.canManage) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addGoal,
            icon: const Icon(Icons.add, size: 18),
            label: Text(widget.team.goalStyle == 'okr' ? 'Add objective' : 'Add KPI'),
          ),
        ],
      ],
    );
  }
}

class _KeyResultDraft {
  final titleCtrl = TextEditingController();
  final targetCtrl = TextEditingController();
}

class _GoalCard extends StatelessWidget {
  final Goal goal;
  final bool canManage;
  final VoidCallback onDelete;
  final VoidCallback onEditKpi;
  final void Function(KeyResult) onEditKeyResult;

  const _GoalCard({
    required this.goal,
    required this.canManage,
    required this.onDelete,
    required this.onEditKpi,
    required this.onEditKeyResult,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(goal.title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                if (canManage) ...[
                  if (!goal.isOkr)
                    IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      tooltip: 'Edit',
                      onPressed: onEditKpi,
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Delete',
                    onPressed: onDelete,
                  ),
                ],
              ],
            ),
            if (!goal.isOkr)
              _ProgressRow(
                current: goal.currentValue,
                target: goal.targetValue,
                unit: goal.unit,
              )
            else
              ...goal.keyResults.map(
                (kr) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: InkWell(
                    onTap: canManage ? () => onEditKeyResult(kr) : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(kr.title, style: theme.textTheme.bodySmall),
                        _ProgressRow(
                          current: kr.currentValue,
                          target: kr.targetValue,
                          unit: kr.unit,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final double current;
  final double target;
  final String unit;

  const _ProgressRow({required this.current, required this.target, required this.unit});

  @override
  Widget build(BuildContext context) {
    final progress = target > 0 ? (current / target).clamp(0.0, 1.0) : 0.0;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: progress, minHeight: 6),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${current.toStringAsFixed(current == current.roundToDouble() ? 0 : 1)}'
            '${unit.isNotEmpty ? ' $unit' : ''} / '
            '${target.toStringAsFixed(target == target.roundToDouble() ? 0 : 1)}'
            '${unit.isNotEmpty ? ' $unit' : ''}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
