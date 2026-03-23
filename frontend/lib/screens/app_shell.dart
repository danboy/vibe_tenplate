import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class AppShell extends StatefulWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _expanded = true;
  String? _lastGroupSlug;

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final groupSlug = _groupSlug(location);
    if (groupSlug != null) _lastGroupSlug = groupSlug;
    final effectiveGroupSlug = groupSlug ?? _lastGroupSlug;
    final selectedIndex = _navIndex(location);

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            expanded: _expanded,
            selectedIndex: selectedIndex,
            groupSlug: effectiveGroupSlug,
            onToggle: () => setState(() => _expanded = !_expanded),
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: Theme.of(context).colorScheme.outline,
          ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }

  String? _groupSlug(String location) {
    final m = RegExp(r'^/groups/([^/]+)').firstMatch(location);
    return m?.group(1);
  }

  int _navIndex(String location) {
    if (_groupSlug(location) != null) return 0;
    return -1;
  }
}

class _Sidebar extends StatelessWidget {
  final bool expanded;
  final int selectedIndex;
  final String? groupSlug;
  final VoidCallback onToggle;

  const _Sidebar({
    required this.expanded,
    required this.selectedIndex,
    required this.groupSlug,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: expanded ? 200.0 : 56.0,
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                IconButton(
                  icon: const Icon(Icons.menu, size: 20),
                  onPressed: onToggle,
                  tooltip: expanded ? 'Collapse sidebar' : 'Expand sidebar',
                ),
                if (expanded) ...[
                  const SizedBox(width: 4),
                  Text(
                    '10Plate',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          _SidebarItem(
            icon: Icons.grid_view_outlined,
            selectedIcon: Icons.grid_view,
            label: 'Projects',
            selected: selectedIndex == 0,
            expanded: expanded,
            onTap: () => context.go(
              groupSlug != null ? '/groups/$groupSlug' : '/groups',
            ),
          ),
          const Spacer(),
          Container(height: 1, color: theme.colorScheme.outlineVariant),
          _UserFooter(expanded: expanded),
        ],
      ),
    );
  }
}

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
        selected ? theme.colorScheme.primary : const Color(0xFF888888);

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
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? theme.colorScheme.primary
                          : const Color(0xFF333333),
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

class _UserFooter extends StatelessWidget {
  final bool expanded;
  const _UserFooter({required this.expanded});

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
        if (value == 'groups') context.go('/groups');
        if (value == 'profile') context.go('/profile');
        if (value == 'logout') auth.logout();
      },
      offset: const Offset(0, -8),
      position: PopupMenuPosition.over,
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'groups', child: Text('My Groups')),
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
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF888888)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.more_vert,
                      size: 16, color: Color(0xFF888888)),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  avatar,
                ],
              ),
      ),
    );
  }
}
