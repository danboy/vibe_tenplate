import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/group.dart';
import '../models/project.dart';
import '../providers/auth_provider.dart';
import 'app_shell.dart';

class GroupWorkspaceScreen extends StatefulWidget {
  final String groupSlug;

  const GroupWorkspaceScreen({super.key, required this.groupSlug});

  @override
  State<GroupWorkspaceScreen> createState() => _GroupWorkspaceScreenState();
}

class _GroupWorkspaceScreenState extends State<GroupWorkspaceScreen> {
  late Future<(Group, List<Project>)> _future;
  List<Project>? _projects; // kept in sync for silent refreshes
  String _search = '';
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) _silentRefreshProjects();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _load() {
    final api = context.read<AuthProvider>().api;
    _projects = null;
    _future = Future.wait([
      api.getGroup(widget.groupSlug),
      api.listProjects(widget.groupSlug),
    ]).then((results) => (results[0] as Group, results[1] as List<Project>));
  }

  // Refresh only the projects list so active user counts update without
  // showing a loading spinner or re-fetching the group.
  void _silentRefreshProjects() {
    final api = context.read<AuthProvider>().api;
    api.listProjects(widget.groupSlug).then((projects) {
      if (!mounted) return;
      setState(() => _projects = projects);
    }).catchError((_) {});
  }

  void _refresh() => setState(() => _load());

  Future<void> _showCreateDialog(Group group) async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final problemCtrl = TextEditingController();
    final iCtrl = _InterstitialControllers();
    final formKey = GlobalKey<FormState>();
    var enableProblem = true;
    var enableVote = true;
    var enablePrioritise = true;
    var guestsEnabled = false;
    final canCustomize = group.plan != 'free';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('New Project'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Project name',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Name is required' : null,
                    autofocus: true,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: problemCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Problem statement (optional)',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                  ),
                  if (canCustomize) ...[
                    const SizedBox(height: 16),
                    Text('Optional slides',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[600])),
                    const SizedBox(height: 4),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Problem Statement'),
                      subtitle: const Text('Collaborative problem statement editor'),
                      value: enableProblem,
                      onChanged: (v) => setLocal(() => enableProblem = v ?? true),
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Vote'),
                      subtitle: const Text('Team members place stars on notes'),
                      value: enableVote,
                      onChanged: (v) => setLocal(() => enableVote = v ?? true),
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Prioritise'),
                      subtitle: const Text('Cost vs value matrix'),
                      value: enablePrioritise,
                      onChanged: (v) =>
                          setLocal(() => enablePrioritise = v ?? true),
                    ),
                    const Divider(height: 20),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Allow guests'),
                      subtitle: const Text('Anyone with the link can join without logging in'),
                      value: guestsEnabled,
                      onChanged: (v) => setLocal(() => guestsEnabled = v ?? false),
                    ),
                    const SizedBox(height: 8),
                    _InterstitialSection(
                      controllers: iCtrl,
                      enableProblem: enableProblem,
                      enableVote: enableVote,
                      enablePrioritise: enablePrioritise,
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.amber.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline, size: 16, color: Colors.amber.shade700),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Upgrade to Standard or Pro to customise activity settings.',
                              style: TextStyle(fontSize: 12, color: Colors.amber.shade800),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
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
      await api.createProject(
        groupSlug: widget.groupSlug,
        name: nameCtrl.text.trim(),
        description: descCtrl.text.trim(),
        problemStatement: problemCtrl.text.trim(),
        enableProblem: enableProblem,
        enableVote: enableVote,
        enablePrioritise: enablePrioritise,
        guestsEnabled: guestsEnabled,
        interstitialProblem: iCtrl.problem.text.trim(),
        interstitialBrainstorm: iCtrl.brainstorm.text.trim(),
        interstitialGroup: iCtrl.group.text.trim(),
        interstitialVote: iCtrl.vote.text.trim(),
        interstitialPrioritise: iCtrl.prioritise.text.trim(),
      );
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _showEditDialog(Project project) async {
    final nameCtrl = TextEditingController(text: project.name);
    final descCtrl = TextEditingController(text: project.description);
    final problemCtrl = TextEditingController(text: project.problemStatement);
    final iCtrl = _InterstitialControllers(
      problem: project.interstitialProblem,
      brainstorm: project.interstitialBrainstorm,
      group: project.interstitialGroup,
      vote: project.interstitialVote,
      prioritise: project.interstitialPrioritise,
    );
    final formKey = GlobalKey<FormState>();
    var enableProblem = project.enableProblem;
    var enableVote = project.enableVote;
    var enablePrioritise = project.enablePrioritise;
    var guestsEnabled = project.guestsEnabled;
    // Fetch group to get current plan
    final group = await context.read<AuthProvider>().api.getGroup(widget.groupSlug);
    if (!mounted) return;
    final canCustomize = group.plan != 'free';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Edit Project'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Project name',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Name is required' : null,
                    autofocus: true,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: problemCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Problem statement (optional)',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                  ),
                  if (canCustomize) ...[
                    const SizedBox(height: 16),
                    Text('Optional slides',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[600])),
                    const SizedBox(height: 4),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Problem Statement'),
                      subtitle: const Text('Collaborative problem statement editor'),
                      value: enableProblem,
                      onChanged: (v) => setLocal(() => enableProblem = v ?? true),
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Vote'),
                      subtitle: const Text('Team members place stars on notes'),
                      value: enableVote,
                      onChanged: (v) => setLocal(() => enableVote = v ?? true),
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Prioritise'),
                      subtitle: const Text('Cost vs value matrix'),
                      value: enablePrioritise,
                      onChanged: (v) =>
                          setLocal(() => enablePrioritise = v ?? true),
                    ),
                    const Divider(height: 20),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Allow guests'),
                      subtitle: const Text('Anyone with the link can join without logging in'),
                      value: guestsEnabled,
                      onChanged: (v) => setLocal(() => guestsEnabled = v ?? false),
                    ),
                    const SizedBox(height: 8),
                    _InterstitialSection(
                      controllers: iCtrl,
                      enableProblem: enableProblem,
                      enableVote: enableVote,
                      enablePrioritise: enablePrioritise,
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.amber.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline, size: 16, color: Colors.amber.shade700),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Upgrade to Standard or Pro to customise activity settings.',
                              style: TextStyle(fontSize: 12, color: Colors.amber.shade800),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
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
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final api = context.read<AuthProvider>().api;
      await api.updateProject(
        groupSlug: widget.groupSlug,
        projectSlug: project.slug,
        name: nameCtrl.text.trim(),
        description: descCtrl.text.trim(),
        problemStatement: problemCtrl.text.trim(),
        enableProblem: enableProblem,
        enableVote: enableVote,
        enablePrioritise: enablePrioritise,
        guestsEnabled: guestsEnabled,
        interstitialProblem: iCtrl.problem.text.trim(),
        interstitialBrainstorm: iCtrl.brainstorm.text.trim(),
        interstitialGroup: iCtrl.group.text.trim(),
        interstitialVote: iCtrl.vote.text.trim(),
        interstitialPrioritise: iCtrl.prioritise.text.trim(),
      );
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _confirmDelete(Group group, Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Project'),
        content: Text(
            'Are you sure you want to delete "${project.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final api = context.read<AuthProvider>().api;
      await api.deleteProject(groupSlug: widget.groupSlug, projectSlug: project.slug);
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
    final theme = Theme.of(context);
    final me = context.read<AuthProvider>().user!;

    return FutureBuilder<(Group, List<Project>)>(
      future: _future,
      builder: (context, snap) {
        final group = snap.data?.$1;
        final projects = snap.data?.$2;

        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.go('/groups'),
            ),
            title: Text(group?.name ?? '…'),
            actions: [
              IconButton(
                icon: const Icon(Icons.people_outlined),
                tooltip: 'Members',
                onPressed: () =>
                    context.go('/groups/${widget.groupSlug}/members'),
              ),
              if (AppShellScope.drawerOpener(context) != null)
                IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: AppShellScope.drawerOpener(context),
                ),
            ],
          ),
          floatingActionButton: group == null
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _showCreateDialog(group),
                  icon: const Icon(Icons.add),
                  label: const Text('New Project'),
                ),
          body: _buildBody(snap, group, projects, me, theme),
        );
      },
    );
  }

  Widget _buildBody(
    AsyncSnapshot<(Group, List<Project>)> snap,
    Group? group,
    List<Project>? projects,
    dynamic me,
    ThemeData theme,
  ) {
    if (snap.connectionState == ConnectionState.waiting) {
      return const Center(child: CircularProgressIndicator());
    }
    // Use the silently-refreshed list if available, so active user counts
    // update without reloading the whole screen.
    projects = _projects ?? projects;
    if (snap.hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 8),
            Text(snap.error.toString()),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: _refresh, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (projects!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            const Text('No projects yet', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              'Create your first project using the button below',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    final filtered = _search.isEmpty
        ? projects
        : projects
            .where((p) =>
                p.name.toLowerCase().contains(_search.toLowerCase()) ||
                p.description.toLowerCase().contains(_search.toLowerCase()))
            .toList();

    if (filtered.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No projects found', style: TextStyle(fontSize: 16)),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search projects…',
              prefixIcon: Icon(Icons.search, size: 20),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
        itemCount: filtered.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final p = filtered[i];
          final canDelete =
              p.createdBy == me.id || group!.ownerId == me.id;
          return _ProjectCard(
            project: p,
            canDelete: canDelete,
            onEdit: canDelete ? () => _showEditDialog(p) : null,
            onDelete: () => _confirmDelete(group!, p),
            onTap: () => context.go(
              '/groups/${widget.groupSlug}/projects/${p.slug}',
            ),
          );
        },
      ),
    ),
        ),
      ],
    );
  }
}


class _ProjectCard extends StatelessWidget {
  final Project project;
  final bool canDelete;
  final VoidCallback? onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onTap;

  const _ProjectCard({
    required this.project,
    required this.canDelete,
    this.onEdit,
    required this.onDelete,
    this.onTap,
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: theme.colorScheme.secondaryContainer,
                child: Icon(Icons.folder,
                    color: theme.colorScheme.onSecondaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(project.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 16)),
                    if (project.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(project.description,
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 13)),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.person_outline,
                            size: 13, color: Colors.grey),
                        const SizedBox(width: 4),
                        Text(project.creatorUsername ?? 'Unknown',
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12)),
                        const SizedBox(width: 12),
                        const Icon(Icons.schedule, size: 13, color: Colors.grey),
                        const SizedBox(width: 4),
                        Text(_formatDate(project.createdAt),
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12)),
                        if (true) ...[
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: project.activeUsers > 0
                                  ? Colors.green.shade100
                                  : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: project.activeUsers > 0
                                        ? Colors.green
                                        : Colors.grey,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${project.activeUsers} active',
                                  style: TextStyle(
                                      color: project.activeUsers > 0
                                          ? Colors.green
                                          : Colors.grey,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (onEdit != null || canDelete)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (value) {
                    if (value == 'edit') onEdit?.call();
                    if (value == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    if (onEdit != null)
                      const PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Edit'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    if (canDelete)
                      const PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: Icon(Icons.delete_outline, color: Colors.red),
                          title: Text('Delete', style: TextStyle(color: Colors.red)),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) =>
      '${dt.day}/${dt.month}/${dt.year}';
}

class _InterstitialControllers {
  final TextEditingController problem;
  final TextEditingController brainstorm;
  final TextEditingController group;
  final TextEditingController vote;
  final TextEditingController prioritise;

  _InterstitialControllers({
    String problem = '',
    String brainstorm = '',
    String group = '',
    String vote = '',
    String prioritise = '',
  })  : problem = TextEditingController(text: problem),
        brainstorm = TextEditingController(text: brainstorm),
        group = TextEditingController(text: group),
        vote = TextEditingController(text: vote),
        prioritise = TextEditingController(text: prioritise);
}

class _InterstitialSection extends StatelessWidget {
  final _InterstitialControllers controllers;
  final bool enableProblem;
  final bool enableVote;
  final bool enablePrioritise;

  const _InterstitialSection({
    required this.controllers,
    required this.enableProblem,
    required this.enableVote,
    required this.enablePrioritise,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        'Advanced',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.grey[600],
        ),
      ),
      children: [
        const SizedBox(height: 4),
        Text(
          'Customise the instructions shown to participants before each activity.',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        const SizedBox(height: 12),
        if (enableProblem) ...[
          _interstitialField(controllers.problem, 'Problem Statement'),
          const SizedBox(height: 12),
        ],
        _interstitialField(controllers.brainstorm, 'Brainstorm'),
        const SizedBox(height: 12),
        _interstitialField(controllers.group, 'Group'),
        if (enableVote) ...[
          const SizedBox(height: 12),
          _interstitialField(controllers.vote, 'Vote'),
        ],
        if (enablePrioritise) ...[
          const SizedBox(height: 12),
          _interstitialField(controllers.prioritise, 'Prioritise'),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _interstitialField(TextEditingController ctrl, String label) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(
        labelText: '$label instructions',
        hintText: 'Leave blank to use the default',
        border: const OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
      maxLines: 3,
    );
  }
}
