import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/group.dart';
import 'app_shell.dart';

class GroupDetailScreen extends StatefulWidget {
  final String groupSlug;

  const GroupDetailScreen({super.key, required this.groupSlug});

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  late Future<Group> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final api = context.read<AuthProvider>().api;
    _future = api.getGroup(widget.groupSlug);
  }

  void _refresh() => setState(() => _load());

  Future<void> _toggleMembership(Group group) async {
    final api = context.read<AuthProvider>().api;
    try {
      if (group.isMember) {
        await api.leaveGroup(group.slug);
      } else {
        await api.joinGroup(group.slug);
      }
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
      body: FutureBuilder<Group>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          if (snap.hasError) {
            return Scaffold(
              appBar: AppBar(),
              body: Center(child: Text(snap.error.toString())),
            );
          }

          final group = snap.data!;
          final me = context.read<AuthProvider>().user!;
          final isOwner = group.ownerId == me.id;

          return Scaffold(
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.go('/groups/${widget.groupSlug}'),
              ),
              title: Text(group.name),
              actions: [
                if (!isOwner)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilledButton.tonal(
                      onPressed: () => _toggleMembership(group),
                      style: FilledButton.styleFrom(
                        backgroundColor: group.isMember
                            ? Theme.of(context).colorScheme.errorContainer
                            : Theme.of(context).colorScheme.primaryContainer,
                        foregroundColor: group.isMember
                            ? Theme.of(context).colorScheme.onErrorContainer
                            : Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                      child: Text(group.isMember ? 'Leave' : 'Join'),
                    ),
                  ),
                if (AppShellScope.drawerOpener(context) != null)
                  IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: AppShellScope.drawerOpener(context),
                  ),
              ],
            ),
            body: RefreshIndicator(
              onRefresh: () async => _refresh(),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _GroupHeader(group: group, isOwner: isOwner),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Text(
                        'Members',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      Chip(
                        label: Text('${group.members.length}'),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...group.members.map((m) => _MemberTile(
                        member: m,
                        isOwner: m.id == group.ownerId,
                        isMe: m.id == me.id,
                      )),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final Group group;
  final bool isOwner;

  const _GroupHeader({required this.group, required this.isOwner});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    group.name[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: 24,
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
                      Text(
                        group.name,
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      if (isOwner)
                        Chip(
                          label: const Text('Owner'),
                          avatar: const Icon(Icons.star, size: 14),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          backgroundColor:
                              theme.colorScheme.secondaryContainer,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (group.description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                group.description,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: Colors.grey.shade600),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final GroupMember member;
  final bool isOwner;
  final bool isMe;

  const _MemberTile({
    required this.member,
    required this.isOwner,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: CircleAvatar(
        backgroundColor: isMe
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceVariant,
        child: Text(
          member.username[0].toUpperCase(),
          style: TextStyle(
            color: isMe
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Row(
        children: [
          Text(member.username),
          if (isMe) ...[
            const SizedBox(width: 4),
            const Text('(you)',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ],
      ),
      subtitle: Text(member.email, style: const TextStyle(fontSize: 12)),
      trailing: isOwner
          ? Chip(
              label: const Text('Owner'),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            )
          : null,
    );
  }
}
