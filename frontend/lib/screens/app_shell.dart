import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../models/group.dart';

// Provides the outer drawer opener to child screens so they can show a
// hamburger button on mobile without needing a nested-Scaffold hack.
class AppShellScope extends InheritedWidget {
  final VoidCallback? openDrawer;

  const AppShellScope({super.key, this.openDrawer, required super.child});

  static VoidCallback? drawerOpener(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppShellScope>()?.openDrawer;

  @override
  bool updateShouldNotify(AppShellScope old) => openDrawer != old.openDrawer;
}

class AppShell extends StatefulWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _expanded = true;
  String? _lastGroupSlug;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  String? _groupSlug(String location) {
    final m = RegExp(r'^/groups/([^/]+)').firstMatch(location);
    return m?.group(1);
  }

  String? _teamSlug(String location) {
    final m = RegExp(r'^/teams/([^/]+)').firstMatch(location);
    return m?.group(1);
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final groupSlug = _groupSlug(location);
    final teamSlugInRoute = _teamSlug(location);
    if (groupSlug != null) _lastGroupSlug = groupSlug;
    final effectiveGroupSlug = groupSlug ?? _lastGroupSlug;
    final onTeamsList = location == '/teams';
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 600;
    final isTablet = width >= 600 && width < 900;

    if (isMobile) {
      return AppShellScope(
        openDrawer: () => _scaffoldKey.currentState?.openDrawer(),
        child: Scaffold(
          key: _scaffoldKey,
          drawer: Drawer(
            child: SafeArea(
              child: _SidebarContent(
                expanded: true,
                groupSlug: effectiveGroupSlug,
                onTeamsList: onTeamsList,
                showToggle: false,
                onToggle: null,
                onItemTap: () => _scaffoldKey.currentState?.closeDrawer(),
              ),
            ),
          ),
          body: widget.child,
        ),
      );
    }

    return AppShellScope(
      child: Scaffold(
        body: Row(
          children: [
            _Sidebar(
              expanded: isTablet ? false : _expanded,
              groupSlug: effectiveGroupSlug,
              onTeamsList: onTeamsList,
              onToggle: isTablet
                  ? null
                  : () => setState(() => _expanded = !_expanded),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: Theme.of(context).colorScheme.outline,
            ),
            Expanded(child: widget.child),
          ],
        ),
      ),
    );
  }
}

// ─── Sidebar (desktop/tablet) ─────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  final bool expanded;
  final String? groupSlug;
  final bool onTeamsList;
  final VoidCallback? onToggle;

  const _Sidebar({
    required this.expanded,
    this.groupSlug,
    required this.onTeamsList,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: expanded ? 200.0 : 56.0,
      color: Theme.of(context).colorScheme.surface,
      child: _SidebarContent(
        expanded: expanded,
        groupSlug: groupSlug,
        onTeamsList: onTeamsList,
        showToggle: onToggle != null,
        onToggle: onToggle,
        onItemTap: null,
      ),
    );
  }
}

// ─── Sidebar content (stateful — loads groups for current team) ───────────────

class _SidebarContent extends StatefulWidget {
  final bool expanded;
  final String? groupSlug;
  final bool onTeamsList;
  final bool showToggle;
  final VoidCallback? onToggle;
  final VoidCallback? onItemTap;

  const _SidebarContent({
    required this.expanded,
    this.groupSlug,
    required this.onTeamsList,
    required this.showToggle,
    this.onToggle,
    this.onItemTap,
  });

  @override
  State<_SidebarContent> createState() => _SidebarContentState();
}

class _SidebarContentState extends State<_SidebarContent> {
  List<Group>? _groups;
  String? _loadedForTeam;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final teamSlug = context.watch<AuthProvider>().currentTeamSlug;
    if (teamSlug != _loadedForTeam) {
      _loadedForTeam = teamSlug;
      _loadGroups(teamSlug);
    }
  }

  Future<void> _loadGroups(String? teamSlug) async {
    if (teamSlug == null) {
      if (mounted) setState(() => _groups = null);
      return;
    }
    try {
      final api = context.read<AuthProvider>().api;
      final groups = await api.listTeamGroups(teamSlug);
      if (mounted && _loadedForTeam == teamSlug) {
        setState(() => _groups = groups);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasHeader = widget.showToggle || widget.expanded;
    final groups = _groups ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        if (hasHeader)
          Container(
            height: kToolbarHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outline),
              ),
            ),
            child: Row(
              children: [
                if (widget.showToggle)
                  IconButton(
                    icon: const Icon(Icons.menu, size: 20),
                    onPressed: widget.onToggle,
                    tooltip: widget.expanded
                        ? 'Collapse sidebar'
                        : 'Expand sidebar',
                  ),
                if (widget.expanded) ...[
                  if (widget.showToggle) const SizedBox(width: 4),
                  SvgPicture.asset('assets/logo.svg', width: 24, height: 24),
                  const SizedBox(width: 8),
                  Text(
                    '10Plate',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ] else if (!widget.showToggle) ...[
                  Expanded(
                    child: Center(
                      child: SvgPicture.asset('assets/logo.svg',
                          width: 24, height: 24),
                    ),
                  ),
                ],
              ],
            ),
          ),

        // ── Teams nav item ────────────────────────────────────────────────
        const SizedBox(height: 8),
        _SidebarItem(
          icon: Icons.group_work_outlined,
          selectedIcon: Icons.group_work,
          label: 'Teams',
          selected: widget.onTeamsList,
          expanded: widget.expanded,
          onTap: () {
            context.go('/teams');
            widget.onItemTap?.call();
          },
        ),

        // ── Groups list ────────────────────────────────────────────────────
        if (groups.isNotEmpty) ...[
          const SizedBox(height: 4),
          if (widget.expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
              child: Text(
                'Groups',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 0.5,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Divider(
                  height: 8,
                  thickness: 1,
                  color: theme.colorScheme.outlineVariant),
            ),
          for (final g in groups)
            _SidebarItem(
              icon: Icons.folder_outlined,
              selectedIcon: Icons.folder,
              label: g.name,
              selected: widget.groupSlug == g.slug,
              expanded: widget.expanded,
              onTap: () {
                context.go('/groups/${g.slug}');
                widget.onItemTap?.call();
              },
            ),
        ],

        const Spacer(),
        Container(height: 1, color: theme.colorScheme.outlineVariant),
        _UserFooter(expanded: widget.expanded, onNavigate: widget.onItemTap),
      ],
    );
  }
}

// ─── Sidebar item ─────────────────────────────────────────────────────────────

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                Icon(selected ? selectedIcon : icon, size: 20, color: color),
                if (expanded) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── User footer ──────────────────────────────────────────────────────────────

class _UserFooter extends StatelessWidget {
  final bool expanded;
  final VoidCallback? onNavigate;

  const _UserFooter({required this.expanded, this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.user;
    if (user == null) return const SizedBox.shrink();
    final theme = Theme.of(context);

    final avatar = CircleAvatar(
      radius: 14,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(
        user.username[0].toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );

    return PopupMenuButton<String>(
      onSelected: (value) {
        if (value == 'teams') {
          context.go('/teams');
          onNavigate?.call();
        }
        if (value == 'profile') {
          context.go('/profile');
          onNavigate?.call();
        }
        if (value == 'logout') auth.logout();
      },
      offset: const Offset(0, -8),
      position: PopupMenuPosition.over,
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'teams', child: Text('My Teams')),
        const PopupMenuItem(value: 'profile', child: Text('Profile')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'logout', child: Text('Log out')),
      ],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: expanded
            ? Row(
                children: [
                  avatar,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          user.username,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          user.email,
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.more_vert,
                      size: 16, color: theme.colorScheme.onSurfaceVariant),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [avatar],
              ),
      ),
    );
  }
}
