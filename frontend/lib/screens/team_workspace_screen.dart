import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/group.dart';
import '../models/team.dart';
import 'app_shell.dart';

class TeamWorkspaceScreen extends StatefulWidget {
  final String teamSlug;

  const TeamWorkspaceScreen({super.key, required this.teamSlug});

  @override
  State<TeamWorkspaceScreen> createState() => _TeamWorkspaceScreenState();
}

class _TeamWorkspaceScreenState extends State<TeamWorkspaceScreen> {
  late Future<(Team, List<Group>)> _future;

  @override
  void initState() {
    super.initState();
    context.read<AuthProvider>().setCurrentTeam(widget.teamSlug);
    _load();
  }

  void _load() {
    final api = context.read<AuthProvider>().api;
    _future = Future.wait([
      api.getTeam(widget.teamSlug),
      api.listTeamGroups(widget.teamSlug),
    ]).then((r) => (r[0] as Team, r[1] as List<Group>));
  }

  void _refresh() => setState(() => _load());

  Future<void> _showCreateGroupDialog(Team team) async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Group'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Group name'),
                validator: (v) =>
                    v == null || v.isEmpty ? 'Name is required' : null,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: descCtrl,
                decoration:
                    const InputDecoration(labelText: 'Description (optional)'),
                maxLines: 2,
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
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final api = context.read<AuthProvider>().api;
      await api.createGroup(
        name: nameCtrl.text.trim(),
        description: descCtrl.text.trim(),
        teamSlug: team.slug,
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
    return FutureBuilder<(Team, List<Group>)>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(child: Text(snap.error.toString())),
          );
        }

        final (team, groups) = snap.data!;
        final myId = context.read<AuthProvider>().user!.id;
        final isOwner = team.ownerId == myId;

        return Scaffold(
          appBar: AppBar(
            title: Text(team.name),
            centerTitle: false,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.go('/teams'),
            ),
            actions: [
              if (isOwner)
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Team settings',
                  onPressed: () => context.go('/teams/${team.slug}/settings'),
                ),
              if (AppShellScope.drawerOpener(context) != null)
                IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: AppShellScope.drawerOpener(context),
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _showCreateGroupDialog(team),
            icon: const Icon(Icons.add),
            label: const Text('New Group'),
          ),
          body: groups.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_open_outlined,
                          size: 64,
                          color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 16),
                      const Text('No groups yet',
                          style: TextStyle(fontSize: 16)),
                      const SizedBox(height: 8),
                      const Text('Create a group to start organising projects',
                          style: TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async => _refresh(),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: groups.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final g = groups[i];
                      return _GroupCard(
                        group: g,
                        isOwner: g.ownerId == myId,
                        onTap: () => context.go('/groups/${g.slug}'),
                        onEdit: () => context.go('/groups/${g.slug}/members'),
                      );
                    },
                  ),
                ),
        );
      },
    );
  }
}

class _GroupCard extends StatelessWidget {
  final Group group;
  final bool isOwner;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  const _GroupCard({
    required this.group,
    required this.isOwner,
    required this.onTap,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  group.name[0].toUpperCase(),
                  style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(group.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 16)),
                      ],
                    ),
                    if (group.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        group.description,
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (group.memberCount > 0)
                Chip(
                  label: Text('${group.memberCount}'),
                  avatar: const Icon(Icons.people, size: 16),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              if (isOwner)
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Group settings',
                  onPressed: onEdit,
                )
              else
                const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
