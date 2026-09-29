import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/team.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late Future<List<Team>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final api = context.read<AuthProvider>().api;
    _future = api.adminListTeams();
  }

  Future<void> _updatePlan(Team team, String newPlan) async {
    try {
      final api = context.read<AuthProvider>().api;
      await api.adminUpdateTeamPlan(team.id, newPlan);
      if (mounted) setState(() => _load());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        centerTitle: false,
      ),
      body: FutureBuilder<List<Team>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text(snap.error.toString()));
          }

          final teams = snap.data!;
          if (teams.isEmpty) {
            return const Center(child: Text('No teams found.'));
          }

          return RefreshIndicator(
            onRefresh: () async => setState(() => _load()),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: teams.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final team = teams[i];
                return _TeamPlanTile(
                  team: team,
                  onPlanChanged: (plan) => _updatePlan(team, plan),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _TeamPlanTile extends StatelessWidget {
  final Team team;
  final ValueChanged<String> onPlanChanged;

  static const _plans = ['free', 'standard', 'pro'];

  const _TeamPlanTile({required this.team, required this.onPlanChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                team.name[0].toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(team.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                  Text(team.slug,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            DropdownButton<String>(
              value: _plans.contains(team.plan) ? team.plan : 'free',
              underline: const SizedBox.shrink(),
              items: _plans
                  .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                  .toList(),
              onChanged: (val) {
                if (val != null && val != team.plan) onPlanChanged(val);
              },
            ),
          ],
        ),
      ),
    );
  }
}
