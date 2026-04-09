import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/team.dart';
import 'app_shell.dart';

class TeamsScreen extends StatefulWidget {
  const TeamsScreen({super.key});

  @override
  State<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends State<TeamsScreen> {
  late Future<List<Team>> _myTeamsFuture;
  Future<List<Team>>? _allTeamsFuture;
  String _search = '';
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _load() {
    _myTeamsFuture = context.read<AuthProvider>().api.listMyTeams();
  }

  void _refresh() => setState(() => _load());

  void _onSearchChanged(String value) {
    final api = context.read<AuthProvider>().api;
    setState(() {
      _search = value;
      if (value.isEmpty) {
        _allTeamsFuture = null;
      } else if (_allTeamsFuture == null) {
        _allTeamsFuture = api.listTeams();
      }
    });
  }

  Future<void> _showJoinByCodeDialog() async {
    final codeCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join with code'),
        content: TextField(
          controller: codeCtrl,
          decoration: const InputDecoration(labelText: 'Invite code'),
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final api = context.read<AuthProvider>().api;
      final result = await api.joinTeamByCode(codeCtrl.text.trim().toUpperCase());
      if (mounted) context.go('/teams/${result.slug}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _joinPublicTeam(Team team) async {
    final api = context.read<AuthProvider>().api;
    try {
      await api.joinTeam(team.slug);
      setState(_load);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _showCreateDialog() async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isPrivate = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Create Team'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Team name'),
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
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Invite only'),
                  subtitle: const Text('Members need a code to join'),
                  value: isPrivate,
                  onChanged: (v) => setLocal(() => isPrivate = v),
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
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final api = context.read<AuthProvider>().api;
      final team = await api.createTeam(
        name: nameCtrl.text.trim(),
        description: descCtrl.text.trim(),
        isPrivate: isPrivate,
      );
      if (mounted) context.go('/teams/${team.slug}');
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
        title: const Text('My Teams'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.vpn_key_outlined),
            tooltip: 'Join with invite code',
            onPressed: _showJoinByCodeDialog,
          ),
          if (AppShellScope.drawerOpener(context) != null)
            IconButton(
              icon: const Icon(Icons.menu),
              onPressed: AppShellScope.drawerOpener(context),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateDialog,
        icon: const Icon(Icons.add),
        label: const Text('New Team'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Find public teams…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _search.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _searchCtrl.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          Expanded(
            child: _search.isEmpty ? _buildMyTeams() : _buildSearchResults(),
          ),
        ],
      ),
    );
  }

  Widget _buildMyTeams() {
    return FutureBuilder<List<Team>>(
      future: _myTeamsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 8),
                Text(snap.error.toString()),
                const SizedBox(height: 16),
                FilledButton.tonal(
                    onPressed: _refresh, child: const Text('Retry')),
              ],
            ),
          );
        }

        final teams = snap.data!;
        if (teams.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.group_work_outlined,
                    size: 64, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 16),
                const Text("You don't have any teams yet",
                    style: TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                const Text(
                  'Create a team or search above to find public ones',
                  style: TextStyle(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: teams.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final t = teams[i];
              final myId = context.read<AuthProvider>().user!.id;
              return _TeamCard(
                team: t,
                isOwner: t.ownerId == myId,
                onTap: () => context.go('/teams/${t.slug}'),
                onSettings: () => context.go('/teams/${t.slug}/settings'),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSearchResults() {
    return FutureBuilder<List<Team>>(
      future: _allTeamsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text(snap.error.toString()));
        }

        final q = _search.toLowerCase();
        final teams = snap.data!
            .where((t) =>
                !t.isMember &&
                !t.isPrivate &&
                (t.name.toLowerCase().contains(q) ||
                    t.description.toLowerCase().contains(q)))
            .toList();

        if (teams.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_off, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text('No public teams found',
                    style: TextStyle(fontSize: 16)),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: teams.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final t = teams[i];
            return _DiscoverCard(team: t, onJoin: () => _joinPublicTeam(t));
          },
        );
      },
    );
  }
}

class _DiscoverCard extends StatelessWidget {
  final Team team;
  final VoidCallback onJoin;

  const _DiscoverCard({required this.team, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              child: Text(
                team.name[0].toUpperCase(),
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.bold,
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
                          fontWeight: FontWeight.w600, fontSize: 16)),
                  if (team.description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      team.description,
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '${team.memberCount} ${team.memberCount == 1 ? 'member' : 'members'}',
                    style: TextStyle(
                        color: theme.colorScheme.outline, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: onJoin,
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundColor: theme.colorScheme.onPrimaryContainer,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 32),
              ),
              child: const Text('Join'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeamCard extends StatelessWidget {
  final Team team;
  final bool isOwner;
  final VoidCallback onTap;
  final VoidCallback onSettings;

  const _TeamCard({
    required this.team,
    required this.isOwner,
    required this.onTap,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPaid = team.plan != 'free';

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
                  team.name[0].toUpperCase(),
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
                        Text(team.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 16)),
                        if (team.isPrivate) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.lock_outline,
                              size: 14, color: Colors.grey),
                        ],
                      ],
                    ),
                    if (team.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        team.description,
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (isPaid) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              team.plan == 'pro' ? 'Pro' : 'Standard',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          '${team.memberCount} ${team.memberCount == 1 ? 'member' : 'members'}',
                          style: TextStyle(
                              color: theme.colorScheme.outline, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (isOwner)
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Team settings',
                  onPressed: onSettings,
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
