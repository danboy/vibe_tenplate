import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/team.dart';
import '../models/admin.dart';
import '../services/api_service.dart';
import '../widgets/confirm_delete_dialog.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  String _section = 'teams';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        centerTitle: false,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'teams', label: Text('Teams')),
                ButtonSegment(value: 'users', label: Text('Users')),
                ButtonSegment(value: 'groups', label: Text('Groups')),
                ButtonSegment(value: 'activities', label: Text('Activities')),
              ],
              selected: {_section},
              onSelectionChanged: (s) => setState(() => _section = s.first),
            ),
          ),
          Expanded(
            child: switch (_section) {
              'users' => _AdminListSection<AdminUserSummary>(
                  key: const ValueKey('users'),
                  fetch: (api) => api.adminListUsers(),
                  delete: (api, user) => api.adminDeleteUser(user.id),
                  deleteTitle: 'Delete User',
                  deleteMessage: (user) =>
                      'Are you sure you want to delete "${user.username}" (${user.email})? '
                      'This cannot be undone.',
                  emptyMessage: 'No users found.',
                  tileBuilder: (user, onDelete) => _UserTile(user: user, onDelete: onDelete),
                ),
              'groups' => _AdminListSection<AdminGroupSummary>(
                  key: const ValueKey('groups'),
                  fetch: (api) => api.adminListGroups(),
                  delete: (api, group) => api.adminDeleteGroup(group.id),
                  deleteTitle: 'Delete Group',
                  deleteMessage: (group) =>
                      'Are you sure you want to delete "${group.name}"? This permanently '
                      'deletes all of its activities too. This cannot be undone.',
                  emptyMessage: 'No groups found.',
                  tileBuilder: (group, onDelete) => _GroupTile(group: group, onDelete: onDelete),
                ),
              'activities' => _AdminListSection<AdminActivitySummary>(
                  key: const ValueKey('activities'),
                  fetch: (api) => api.adminListBrainstorms(),
                  delete: (api, activity) => api.adminDeleteBrainstorm(activity.id),
                  deleteTitle: 'Delete Activity',
                  deleteMessage: (activity) =>
                      'Are you sure you want to delete "${activity.name}"? This cannot be undone.',
                  emptyMessage: 'No activities found.',
                  tileBuilder: (activity, onDelete) =>
                      _ActivityTile(activity: activity, onDelete: onDelete),
                ),
              _ => const _TeamsSection(),
            },
          ),
        ],
      ),
    );
  }
}

// ─── Generic list-with-delete section, shared by Users/Groups/Activities ────
//
// Teams isn't built on this: its tiles also drive a plan-change mutation
// that isn't a delete, which doesn't fit this shape without bending it.

class _AdminListSection<T> extends StatefulWidget {
  final Future<List<T>> Function(ApiService api) fetch;
  final Future<void> Function(ApiService api, T item) delete;
  final String deleteTitle;
  final String Function(T item) deleteMessage;
  final Widget Function(T item, VoidCallback onDelete) tileBuilder;
  final String emptyMessage;

  const _AdminListSection({
    super.key,
    required this.fetch,
    required this.delete,
    required this.deleteTitle,
    required this.deleteMessage,
    required this.tileBuilder,
    required this.emptyMessage,
  });

  @override
  State<_AdminListSection<T>> createState() => _AdminListSectionState<T>();
}

class _AdminListSectionState<T> extends State<_AdminListSection<T>> {
  late Future<List<T>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final api = context.read<AuthProvider>().api;
    _future = widget.fetch(api);
  }

  Future<void> _delete(T item) async {
    final confirmed = await confirmDelete(
      context,
      title: widget.deleteTitle,
      message: widget.deleteMessage(item),
    );
    if (!confirmed || !mounted) return;
    try {
      final api = context.read<AuthProvider>().api;
      await widget.delete(api, item);
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
    return FutureBuilder<List<T>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text(snap.error.toString()));
        }
        final items = snap.data!;
        if (items.isEmpty) {
          return Center(child: Text(widget.emptyMessage));
        }
        return RefreshIndicator(
          onRefresh: () async => setState(() => _load()),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final item = items[i];
              return widget.tileBuilder(item, () => _delete(item));
            },
          ),
        );
      },
    );
  }
}

// ─── Teams ──────────────────────────────────────────────────────────────────

class _TeamsSection extends StatefulWidget {
  const _TeamsSection();

  @override
  State<_TeamsSection> createState() => _TeamsSectionState();
}

class _TeamsSectionState extends State<_TeamsSection> {
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

  Future<void> _delete(Team team) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Delete Team',
      message:
          'Are you sure you want to delete "${team.name}"? This permanently '
          'deletes all of its groups and their activities too. This cannot '
          'be undone.',
    );
    if (!confirmed || !mounted) return;
    try {
      final api = context.read<AuthProvider>().api;
      await api.adminDeleteTeam(team.id);
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
    return FutureBuilder<List<Team>>(
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
                onDelete: () => _delete(team),
              );
            },
          ),
        );
      },
    );
  }
}

class _DeleteIconButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback onPressed;

  const _DeleteIconButton({required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) => IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: tooltip,
        onPressed: onPressed,
      );
}

class _TeamPlanTile extends StatelessWidget {
  final Team team;
  final ValueChanged<String> onPlanChanged;
  final VoidCallback onDelete;

  static const _plans = ['free', 'standard', 'pro'];

  const _TeamPlanTile({
    required this.team,
    required this.onPlanChanged,
    required this.onDelete,
  });

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
            _DeleteIconButton(tooltip: 'Delete team', onPressed: onDelete),
          ],
        ),
      ),
    );
  }
}

// ─── Users ──────────────────────────────────────────────────────────────────

class _UserTile extends StatelessWidget {
  final AdminUserSummary user;
  final VoidCallback onDelete;

  const _UserTile({required this.user, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(user.username[0].toUpperCase(),
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onPrimaryContainer)),
        ),
        title: Row(
          children: [
            Text(user.username),
            if (user.isAdmin) ...[
              const SizedBox(width: 8),
              const Chip(
                label: Text('admin', style: TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ],
        ),
        subtitle: Text(user.email),
        trailing: _DeleteIconButton(tooltip: 'Delete user', onPressed: onDelete),
      ),
    );
  }
}

// ─── Groups ─────────────────────────────────────────────────────────────────

class _GroupTile extends StatelessWidget {
  final AdminGroupSummary group;
  final VoidCallback onDelete;

  const _GroupTile({required this.group, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(group.name),
        subtitle: Text(
          group.teamName.isNotEmpty
              ? '${group.teamName} · ${group.memberCount} members · owner: ${group.ownerUsername}'
              : '${group.memberCount} members · owner: ${group.ownerUsername}',
        ),
        trailing: _DeleteIconButton(tooltip: 'Delete group', onPressed: onDelete),
      ),
    );
  }
}

// ─── Activities ─────────────────────────────────────────────────────────────

class _ActivityTile extends StatelessWidget {
  final AdminActivitySummary activity;
  final VoidCallback onDelete;

  const _ActivityTile({required this.activity, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(activity.name),
        subtitle: Text(
          '${activity.groupName.isNotEmpty ? activity.groupName : activity.groupId}'
          '${activity.teamName.isNotEmpty ? ' · ${activity.teamName}' : ''}'
          ' · ${activity.type}'
          '${activity.creatorUsername.isNotEmpty ? ' · by ${activity.creatorUsername}' : ''}',
        ),
        trailing: _DeleteIconButton(tooltip: 'Delete activity', onPressed: onDelete),
      ),
    );
  }
}
