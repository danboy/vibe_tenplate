import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/group.dart';
import '../services/api_service.dart';
import 'app_shell.dart';

class MyGroupsScreen extends StatefulWidget {
  const MyGroupsScreen({super.key});

  @override
  State<MyGroupsScreen> createState() => _MyGroupsScreenState();
}

class _MyGroupsScreenState extends State<MyGroupsScreen> {
  late Future<List<Group>> _future;
  Future<List<Group>>? _allGroupsFuture;
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
    final api = context.read<AuthProvider>().api;
    _future = api.getMyGroups();
    if (_search.isNotEmpty) {
      _allGroupsFuture = api.listGroups();
    }
  }

  void _refresh() => setState(() => _load());

  void _onSearchChanged(String value) {
    final api = context.read<AuthProvider>().api;
    setState(() {
      _search = value;
      if (value.isEmpty) {
        _allGroupsFuture = null;
      } else if (_allGroupsFuture == null) {
        _allGroupsFuture = api.listGroups();
      }
    });
  }

  Future<void> _joinGroup(Group group) async {
    final api = context.read<AuthProvider>().api;
    try {
      if (group.isPrivate) {
        await _joinWithCode(group, api);
      } else {
        await api.joinGroup(group.slug);
        setState(_load);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _joinWithCode(Group group, ApiService api) async {
    final codeCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.lock_outline, size: 18),
            const SizedBox(width: 8),
            Text('Join ${group.name}'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This group is invite only. Enter the invite code to join.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeCtrl,
              decoration: const InputDecoration(labelText: 'Invite code'),
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
            ),
          ],
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
    await api.joinGroup(group.slug, code: codeCtrl.text.trim());
    setState(_load);
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
          title: const Text('Create Group'),
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
      await api.createGroup(
        name: nameCtrl.text.trim(),
        description: descCtrl.text.trim(),
        isPrivate: isPrivate,
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Groups'),
        centerTitle: false,
        actions: [
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
        label: const Text('New Group'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Find public groups…',
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
            child: _search.isEmpty ? _buildMyGroups() : _buildSearchResults(),
          ),
        ],
      ),
    );
  }

  Widget _buildMyGroups() {
    return FutureBuilder<List<Group>>(
      future: _future,
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
                  onPressed: _refresh,
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        final groups = snap.data!;
        if (groups.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.group_off,
                    size: 64, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 16),
                const Text(
                  "You haven't joined any groups yet",
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Search above to find and join public groups',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: groups.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final g = groups[i];
              final myId = context.read<AuthProvider>().user!.id;
              return _GroupCard(
                group: g,
                isOwner: g.ownerId == myId,
                onTap: () => context.go('/groups/${g.slug}'),
                onEdit: () => context.go('/groups/${g.slug}/members'),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSearchResults() {
    return FutureBuilder<List<Group>>(
      future: _allGroupsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text(snap.error.toString()));
        }

        final q = _search.toLowerCase();
        final groups = snap.data!
            .where((g) =>
                !g.isMember &&
                (g.name.toLowerCase().contains(q) ||
                    g.description.toLowerCase().contains(q)))
            .toList();

        if (groups.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_off, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text('No public groups found',
                    style: TextStyle(fontSize: 16)),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: groups.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final g = groups[i];
            return _DiscoverCard(
              group: g,
              onJoin: () => _joinGroup(g),
            );
          },
        );
      },
    );
  }
}

class _DiscoverCard extends StatelessWidget {
  final Group group;
  final VoidCallback onJoin;

  const _DiscoverCard({required this.group, required this.onJoin});

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
                group.name[0].toUpperCase(),
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
                  Row(
                    children: [
                      Text(group.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 16)),
                      if (group.isPrivate) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.lock_outline,
                            size: 14, color: Colors.grey),
                      ],
                    ],
                  ),
                  if (group.description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      group.description,
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '${group.memberCount} ${group.memberCount == 1 ? 'member' : 'members'}',
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
              child: Text(group.isPrivate ? 'Join with Code' : 'Join'),
            ),
          ],
        ),
      ),
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
                        if (group.isPrivate) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.lock_outline,
                              size: 14, color: Colors.grey),
                        ],
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
                  tooltip: 'Edit group',
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
