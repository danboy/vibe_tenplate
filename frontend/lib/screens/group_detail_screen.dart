import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
                  if (isOwner) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Plan',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    _GroupPlanSelector(
                      group: group,
                      onPlanChanged: _refresh,
                    ),
                  ],
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
            if (isOwner &&
                group.joinCode != null &&
                group.joinCode!.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.lock_outline, size: 14, color: Colors.grey),
                  const SizedBox(width: 6),
                  const Text(
                    'Invite code',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: theme.colorScheme.outline),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        group.joinCode!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      tooltip: 'Copy code',
                      onPressed: () {
                        Clipboard.setData(
                            ClipboardData(text: group.joinCode!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Invite code copied'),
                              duration: Duration(seconds: 2)),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _InviteLink(group: group),
            ],
          ],
        ),
      ),
    );
  }
}

class _InviteLink extends StatelessWidget {
  final Group group;
  const _InviteLink({required this.group});

  String get _link {
    final base = Uri.base;
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.port,
      path: '/join',
      queryParameters: {'code': group.joinCode},
    ).toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = _link;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        children: [
          const Icon(Icons.link, size: 16, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              link,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined, size: 18),
            tooltip: 'Copy invite link',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Invite link copied'),
                    duration: Duration(seconds: 2)),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _GroupPlanSelector extends StatefulWidget {
  final Group group;
  final VoidCallback onPlanChanged;

  const _GroupPlanSelector({required this.group, required this.onPlanChanged});

  @override
  State<_GroupPlanSelector> createState() => _GroupPlanSelectorState();
}

class _GroupPlanSelectorState extends State<_GroupPlanSelector> {
  bool _loading = false;

  Future<void> _selectPlan(String plan) async {
    if (plan == widget.group.plan || _loading) return;
    setState(() => _loading = true);
    try {
      await context.read<AuthProvider>().api.updateGroupPlan(widget.group.slug, plan);
      widget.onPlanChanged();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PlanCard(
          name: 'Free',
          planKey: 'free',
          currentPlan: widget.group.plan,
          features: const ['3 projects', 'Default activity settings'],
          onSelect: _loading ? null : () => _selectPlan('free'),
        ),
        const SizedBox(height: 10),
        _PlanCard(
          name: 'Standard',
          planKey: 'standard',
          currentPlan: widget.group.plan,
          features: const ['Unlimited projects', 'Custom activity settings'],
          onSelect: _loading ? null : () => _selectPlan('standard'),
        ),
        const SizedBox(height: 10),
        _PlanCard(
          name: 'Pro',
          planKey: 'pro',
          currentPlan: widget.group.plan,
          features: const ['Unlimited projects', 'Custom activity settings', 'Priority support'],
          onSelect: _loading ? null : () => _selectPlan('pro'),
        ),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String name;
  final String planKey;
  final String currentPlan;
  final List<String> features;
  final VoidCallback? onSelect;

  const _PlanCard({
    required this.name,
    required this.planKey,
    required this.currentPlan,
    required this.features,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isActive = currentPlan == planKey;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? theme.colorScheme.primary : Colors.grey.shade300,
          width: isActive ? 2 : 1,
        ),
        color: isActive
            ? theme.colorScheme.primary.withValues(alpha: 0.05)
            : theme.colorScheme.surface,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isActive ? null : onSelect,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: isActive ? theme.colorScheme.primary : null,
                          ),
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Current',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...features.map(
                      (f) => Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(Icons.check,
                                size: 14,
                                color: isActive
                                    ? theme.colorScheme.primary
                                    : Colors.grey),
                            const SizedBox(width: 6),
                            Text(f,
                                style: TextStyle(
                                    fontSize: 13, color: Colors.grey[700])),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!isActive)
                Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
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
