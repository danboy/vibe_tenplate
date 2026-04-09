// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/team.dart';
import 'app_shell.dart';

class TeamDetailScreen extends StatefulWidget {
  final String teamSlug;

  const TeamDetailScreen({super.key, required this.teamSlug});

  @override
  State<TeamDetailScreen> createState() => _TeamDetailScreenState();
}

class _TeamDetailScreenState extends State<TeamDetailScreen> {
  late Future<Team> _future;
  bool _awaitingPlanUpdate = false;

  @override
  void initState() {
    super.initState();
    context.read<AuthProvider>().setCurrentTeam(widget.teamSlug);
    _load();
    if (Uri.base.queryParameters['billing'] == 'success') {
      _awaitingPlanUpdate = true;
      _pollForPlanUpdate();
    }
  }

  Future<void> _pollForPlanUpdate() async {
    const maxAttempts = 20;
    final api = context.read<AuthProvider>().api;

    for (var i = 0; i < maxAttempts; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final team = await api.getTeam(widget.teamSlug);
        if (team.plan != 'free') {
          html.window.history.replaceState(
            null,
            '',
            Uri.base.replace(queryParameters: {}).toString(),
          );
          setState(() {
            _future = Future.value(team);
            _awaitingPlanUpdate = false;
          });
          return;
        }
      } catch (_) {}
    }

    if (mounted) setState(() => _awaitingPlanUpdate = false);
  }

  void _load() {
    _future = context.read<AuthProvider>().api.getTeam(widget.teamSlug);
  }

  void _refresh() => setState(() => _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<Team>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) {
            return Scaffold(
              appBar: AppBar(),
              body: Center(child: Text(snap.error.toString())),
            );
          }

          final team = snap.data!;
          final me = context.read<AuthProvider>().user!;
          final isOwner = team.ownerId == me.id;

          return Scaffold(
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.go('/teams/${widget.teamSlug}'),
              ),
              title: Text(team.name),
              actions: [
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
                  _TeamHeader(team: team, isOwner: isOwner),
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
                        label: Text('${team.members.length}'),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...team.members.map((m) => _MemberTile(
                        member: m,
                        isOwner: m.id == team.ownerId,
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
                    if (_awaitingPlanUpdate)
                      const _PlanConfirmingBanner()
                    else
                      _TeamPlanSelector(
                        team: team,
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

class _TeamHeader extends StatelessWidget {
  final Team team;
  final bool isOwner;

  const _TeamHeader({required this.team, required this.isOwner});

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
                    team.name[0].toUpperCase(),
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
                        team.name,
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
                          backgroundColor: theme.colorScheme.secondaryContainer,
                        ),
                      if (team.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          team.description,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: Colors.grey.shade600),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (isOwner &&
                team.isPrivate &&
                team.joinCode != null &&
                team.joinCode!.isNotEmpty) ...[
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
                        team.joinCode!,
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
                            ClipboardData(text: team.joinCode!));
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
              const SizedBox(height: 8),
              _InviteLink(team: team),
            ],
          ],
        ),
      ),
    );
  }
}

class _InviteLink extends StatelessWidget {
  final Team team;
  const _InviteLink({required this.team});

  String get _link {
    final base = Uri.base;
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.port,
      path: '/join',
      queryParameters: {'code': team.joinCode},
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

class _PlanConfirmingBanner extends StatelessWidget {
  const _PlanConfirmingBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.4)),
        color: theme.colorScheme.primary.withValues(alpha: 0.05),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(
            'Confirming payment…',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeamPlanSelector extends StatefulWidget {
  final Team team;
  final VoidCallback onPlanChanged;

  const _TeamPlanSelector({required this.team, required this.onPlanChanged});

  @override
  State<_TeamPlanSelector> createState() => _TeamPlanSelectorState();
}

class _TeamPlanSelectorState extends State<_TeamPlanSelector> {
  bool _loading = false;

  Future<void> _redirectToCheckout(String plan) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final api = context.read<AuthProvider>().api;
      final successUrl = Uri.base
          .replace(queryParameters: {'billing': 'success'})
          .toString();
      final url = await api.createTeamCheckoutSession(
        teamSlug: widget.team.slug,
        plan: plan,
        successUrl: successUrl,
        cancelUrl: Uri.base.toString(),
      );
      html.window.location.href = url;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _redirectToPortal() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final api = context.read<AuthProvider>().api;
      final url = await api.createTeamBillingPortalSession(
        teamSlug: widget.team.slug,
        returnUrl: Uri.base.toString(),
      );
      html.window.location.href = url;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPaid = widget.team.plan != 'free';

    if (isPaid) {
      return _PaidPlanView(
        team: widget.team,
        loading: _loading,
        onManageBilling: _redirectToPortal,
      );
    }

    return Column(
      children: [
        _PlanCard(
          name: 'Free',
          planKey: 'free',
          currentPlan: widget.team.plan,
          price: null,
          features: const ['3 projects per group', 'Default activity settings'],
          onSelect: null,
        ),
        const SizedBox(height: 10),
        _PlanCard(
          name: 'Standard',
          planKey: 'standard',
          currentPlan: widget.team.plan,
          price: '\$4.99 / month',
          features: const [
            'Unlimited projects',
            'Custom activity settings',
            'Guest access'
          ],
          onSelect: _loading ? null : () => _redirectToCheckout('standard'),
        ),
        const SizedBox(height: 10),
        _PlanCard(
          name: 'Pro',
          planKey: 'pro',
          currentPlan: widget.team.plan,
          price: '\$9.99 / month',
          features: const [
            'Unlimited projects',
            'Custom activity settings',
            'Guest access'
          ],
          onSelect: _loading ? null : () => _redirectToCheckout('pro'),
        ),
        if (_loading) ...[
          const SizedBox(height: 16),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    );
  }
}

class _PaidPlanView extends StatelessWidget {
  final Team team;
  final bool loading;
  final VoidCallback onManageBilling;

  const _PaidPlanView({
    required this.team,
    required this.loading,
    required this.onManageBilling,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final planName = team.plan == 'pro' ? 'Pro' : 'Standard';
    final planPrice =
        team.plan == 'pro' ? '\$9.99 / month' : '\$4.99 / month';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.primary, width: 2),
        color: theme.colorScheme.primary.withValues(alpha: 0.05),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                planName,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Active',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                planPrice,
                style:
                    theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: loading ? null : onManageBilling,
              icon: loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_new, size: 16),
              label: const Text('Manage billing'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String name;
  final String planKey;
  final String currentPlan;
  final String? price;
  final List<String> features;
  final VoidCallback? onSelect;

  const _PlanCard({
    required this.name,
    required this.planKey,
    required this.currentPlan,
    required this.price,
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
                        if (price != null) ...[
                          const Spacer(),
                          Text(
                            price!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.grey[600],
                              fontWeight: FontWeight.w600,
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
              if (!isActive && onSelect != null)
                FilledButton.tonal(
                  onPressed: onSelect,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 32),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Upgrade'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final TeamMember member;
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
            : theme.colorScheme.surfaceContainerHighest,
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
