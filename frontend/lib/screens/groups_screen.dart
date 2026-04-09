import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/group.dart';
import 'app_shell.dart';

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  late Future<List<Group>> _future;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final api = context.read<AuthProvider>().api;
    _future = api.listGroups();
  }

  void _refresh() => setState(() => _load());

  Future<void> _toggleMembership(Group group) async {
    final api = context.read<AuthProvider>().api;
    try {
      if (group.isMember) {
        await api.leaveGroup(group.slug);
        _refresh();
      } else {
        await api.joinGroup(group.slug);
        _refresh();
      }
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
        title: const Text('Discover Groups'),
        centerTitle: false,
        actions: [
          if (AppShellScope.drawerOpener(context) != null)
            IconButton(
              icon: const Icon(Icons.menu),
              onPressed: AppShellScope.drawerOpener(context),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SearchBar(
              hintText: 'Search groups...',
              leading: const Icon(Icons.search),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
        ),
      ),
      body: FutureBuilder<List<Group>>(
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

          final groups = snap.data!
              .where((g) =>
                  _search.isEmpty ||
                  g.name.toLowerCase().contains(_search.toLowerCase()) ||
                  g.description.toLowerCase().contains(_search.toLowerCase()))
              .toList();

          if (groups.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.search_off, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No groups found', style: TextStyle(fontSize: 16)),
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
                return _DiscoverCard(
                  group: g,
                  onTap: () => context.go('/groups/${g.slug}'),
                  onToggle: () => _toggleMembership(g),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _DiscoverCard extends StatelessWidget {
  final Group group;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  const _DiscoverCard({
    required this.group,
    required this.onTap,
    required this.onToggle,
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
                backgroundColor: group.isMember
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                child: Text(
                  group.name[0].toUpperCase(),
                  style: TextStyle(
                    color: group.isMember
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16),
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
                onPressed: onToggle,
                style: FilledButton.styleFrom(
                  backgroundColor: group.isMember
                      ? theme.colorScheme.errorContainer
                      : theme.colorScheme.primaryContainer,
                  foregroundColor: group.isMember
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onPrimaryContainer,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 32),
                ),
                child: Text(group.isMember ? 'Leave' : 'Join'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
