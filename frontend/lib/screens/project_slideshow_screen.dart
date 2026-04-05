import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show PointMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/group.dart';
import '../models/project.dart';
import '../models/sticky_note.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';

class ProjectSlideshowScreen extends StatefulWidget {
  final String groupSlug;
  final String projectSlug;

  const ProjectSlideshowScreen({
    super.key,
    required this.groupSlug,
    required this.projectSlug,
  });

  @override
  State<ProjectSlideshowScreen> createState() =>
      _ProjectSlideshowScreenState();
}

class _ProjectSlideshowScreenState extends State<ProjectSlideshowScreen> {
  WebSocketChannel? _channel;
  List<StickyNote> _notes = [];
  bool _connected = false;
  final _rng = Random();
  Project? _project;
  Group? _group;
  bool _loginRequired = false;
  bool _isGuest = false;

  // 0 = problem, 1 = brainstorm, 2 = group, 3 = vote, 4 = prioritise
  int _slide = 0;
  String _problemStatement = '';
  Timer? _psDebounce;
  bool _wsInitialized = false;
  final Set<int> _dismissedInterstitials = {};

  bool get _showInterstitial =>
      _wsInitialized && !_dismissedInterstitials.contains(_slide);

  // Viewport state
  Offset _offset = Offset.zero;
  double _scale = 1.0;

  // Gesture tracking
  Offset _gestureStartOffset = Offset.zero;
  double _gestureStartScale = 1.0;
  Offset _gestureStartFocal = Offset.zero;
  bool _isDraggingNote = false;

  // Per-group drag offsets so all members move together in real-time.
  final Map<String, Offset> _groupDragOffsets = {};

  // votes: noteId → userId → count
  final Map<String, Map<String, int>> _votes = {};

  // Matrix positions for slide 2: normalized (dx=cost 0-1, dy=value 0-1, 1=high)
  final Map<String, Offset> _matrixPositions = {};
  // noteID → userID of whoever is currently dragging that item
  final Map<String, String> _matrixLockedBy = {};

  void _onMatrixPositionChanged(String id, Offset normalized) {
    setState(() => _matrixPositions[id] = normalized);
    _send('matrix_move', {'id': id, 'cost': normalized.dx, 'value': normalized.dy});
  }

  void _onMatrixDragStart(String id) {
    _send('matrix_drag_start', {'id': id});
  }

  void _onMatrixDragEnd(String id) {
    _send('matrix_drag_end', {'id': id});
  }

  void _onGroupDragUpdate(String groupId, double dx, double dy) {
    setState(() {
      final c = _groupDragOffsets[groupId] ?? Offset.zero;
      _groupDragOffsets[groupId] = Offset(c.dx + dx, c.dy + dy);
    });
  }

  void _onGroupDragEnd(String groupId) {
    setState(() => _groupDragOffsets.remove(groupId));
  }

  bool _viewportInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_viewportInitialized) {
      final size = MediaQuery.of(context).size;
      _offset = Offset(size.width / 2, size.height / 2);
      _viewportInitialized = true;
    }
  }

  static const _prefsKey = 'dismissed_interstitials';

  @override
  void initState() {
    super.initState();
    _loadDismissed();
    _loadAndConnect();
  }

  Future<void> _loadDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKey) ?? [];
    if (mounted) {
      setState(() => _dismissedInterstitials.addAll(saved.map(int.parse)));
    }
  }

  Future<void> _saveDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setStringList(
      _prefsKey,
      _dismissedInterstitials.map((i) => '$i').toList(),
    );
  }

  Future<void> _loadAndConnect() async {
    final auth = context.read<AuthProvider>();

    if (auth.isAuthenticated) {
      try {
        final api = auth.api;
        final results = await Future.wait([
          api.getProject(groupSlug: widget.groupSlug, projectSlug: widget.projectSlug),
          api.getGroup(widget.groupSlug),
        ]);
        if (!mounted) return;
        final project = results[0] as Project;
        setState(() {
          _project = project;
          _group = results[1] as Group;
          if (!project.enableProblem && _slide == 0) _slide = 1;
        });
        _connect(project.id);
      } catch (_) {}
    } else {
      // Unauthenticated — check if guests are enabled for this project.
      try {
        final info = await ApiService().getGuestProject(
            widget.groupSlug, widget.projectSlug);
        if (!mounted) return;
        if (info['guests_enabled'] != true) {
          setState(() => _loginRequired = true);
          return;
        }
        // Show display name prompt after the frame is drawn.
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          final name = await _showGuestNameDialog();
          if (name == null || !mounted) return;
          final token = await ApiService()
              .guestJoin(info['id'] as String, name);
          if (!mounted) return;
          setState(() {
            _isGuest = true;
            // Minimal project info for guests
            _project = Project(
              id: info['id'] as String,
              slug: widget.projectSlug,
              name: info['name'] as String,
              description: '',
              groupId: '',
              createdBy: '',
              createdAt: DateTime.now(),
              enableProblem: info['enable_problem'] as bool? ?? true,
            );
            if (_project?.enableProblem == false && _slide == 0) _slide = 1;
          });
          _connect(info['id'] as String, guestToken: token);
        });
      } catch (_) {
        if (mounted) setState(() => _loginRequired = true);
      }
    }
  }

  Future<String?> _showGuestNameDialog() {
    final ctrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Join as Guest'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: ctrl,
            decoration: const InputDecoration(
              labelText: 'Your display name',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
            validator: (v) =>
                v == null || v.trim().isEmpty ? 'Name is required' : null,
            onFieldSubmitted: (_) {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, ctrl.text.trim());
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, ctrl.text.trim());
              }
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  bool get _isPresenter {
    if (_isGuest) return false;
    final userId = context.read<AuthProvider>().user?.id;
    if (userId == null || _project == null) return false;
    if (_project!.presenterId != null) return userId == _project!.presenterId;
    return userId == _project!.createdBy;
  }

  bool get _canAssignPresenter {
    if (_isGuest) return false;
    final userId = context.read<AuthProvider>().user?.id;
    if (userId == null || _project == null) return false;
    return userId == _project!.createdBy || userId == _group?.ownerId;
  }

  void _connect(String projectId, {String? guestToken}) {
    final token = guestToken ?? context.read<AuthProvider>().token;
    final uri = Uri.parse(
        '${ApiService.wsBaseUrl}/ws/projects/$projectId?token=$token');
    _channel = WebSocketChannel.connect(uri);
    setState(() => _connected = true);
    _channel!.stream.listen(
      _handleMessage,
      onDone: () => setState(() => _connected = false),
      onError: (_) => setState(() => _connected = false),
    );
  }

  void _handleMessage(dynamic data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    final type = msg['type'] as String;
    final payload = msg['payload'];

    setState(() {
      switch (type) {
        case 'init':
          final p = payload as Map<String, dynamic>;
          final list = (p['notes'] as List? ?? []);
          _notes = list
              .map((n) => StickyNote.fromJson(n as Map<String, dynamic>))
              .toList();
          _slide = (p['slide'] as int?) ?? 0;
          _matrixPositions.clear();
          for (final note in _notes) {
            if (note.matrixCost != null && note.matrixValue != null) {
              _matrixPositions[note.id] =
                  Offset(note.matrixCost!, note.matrixValue!);
            }
          }
          _votes.clear();
          for (final v in (p['votes'] as List? ?? [])) {
            final vMap = v as Map<String, dynamic>;
            _votes.putIfAbsent(vMap['note_id'] as String, () => {})[
                vMap['user_id'] as String] = vMap['count'] as int;
          }
          _problemStatement = (p['problem_statement'] as String?) ?? '';
          _wsInitialized = true;
          if (_notes.isNotEmpty && (_slide == 1 || _slide == 2 || _slide == 3)) {
            _centerIfNeeded();
          }

        case 'note_create':
          _notes.add(StickyNote.fromJson(payload as Map<String, dynamic>));

        case 'note_move':
          final id = payload['id'] as String;
          final idx = _notes.indexWhere((n) => n.id == id);
          if (idx != -1) {
            _notes[idx] = _notes[idx].copyWith(
              posX: (payload['pos_x'] as num).toDouble(),
              posY: (payload['pos_y'] as num).toDouble(),
            );
          }

        case 'note_update':
          final id = payload['id'] as String;
          final idx = _notes.indexWhere((n) => n.id == id);
          if (idx != -1) {
            _notes[idx] = _notes[idx].copyWith(
              content: payload['content'] as String,
            );
          }

        case 'note_delete':
          _notes.removeWhere((n) => n.id == payload['id'] as String);

        case 'note_group':
          final id = payload['id'] as String;
          final parentId = payload['parent_id'] as String?;
          final idx = _notes.indexWhere((n) => n.id == id);
          if (idx != -1) {
            _notes[idx] = parentId == null
                ? _notes[idx].copyWith(clearParent: true)
                : _notes[idx].copyWith(parentId: parentId);
          }

        case 'matrix_drag_start':
          _matrixLockedBy[payload['id'] as String] =
              payload['user_id'] as String;

        case 'matrix_drag_end':
          _matrixLockedBy.remove(payload['id'] as String);

        case 'matrix_move':
          final id = payload['id'] as String;
          _matrixPositions[id] = Offset(
            (payload['cost'] as num).toDouble(),
            (payload['value'] as num).toDouble(),
          );

        case 'slide_change':
          _slide = payload['slide'] as int;

        case 'problem_statement_update':
          _problemStatement = (payload['text'] as String?) ?? '';

        case 'presenter_change':
          if (_project != null) {
            final pid = payload['presenter_id'] as String?;
            final pname = payload['presenter_username'] as String?;
            _project = pid == null
                ? _project!.copyWith(clearPresenter: true)
                : _project!.copyWith(presenterId: pid, presenterUsername: pname);
          }

        case 'vote':
          final noteId = payload['note_id'] as String;
          final userId = payload['user_id'] as String;
          final count = payload['count'] as int;
          _votes.putIfAbsent(noteId, () => {})[userId] = count;
      }
    });
  }

  void _send(String type, Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode({'type': type, 'payload': payload}));
  }

  void _moveNote(String id, double worldX, double worldY) {
    final idx = _notes.indexWhere((n) => n.id == id);
    if (idx == -1) return;
    final note = _notes[idx];

    if (note.isGroup) {
      // Dragging the group parent moves the whole group.
      final dx = worldX - note.posX;
      final dy = worldY - note.posY;
      setState(() {
        for (int i = 0; i < _notes.length; i++) {
          final n = _notes[i];
          if (n.id == id || n.parentId == id) {
            _notes[i] = n.copyWith(
              posX: n.id == id ? worldX : n.posX + dx,
              posY: n.id == id ? worldY : n.posY + dy,
            );
          }
        }
      });
      for (final m in _notes.where((n) => n.id == id || n.parentId == id)) {
        _send('note_move', {'id': m.id, 'pos_x': m.posX, 'pos_y': m.posY});
      }
    } else {
      // Child or ungrouped note moves independently.
      setState(() {
        _notes[idx] = _notes[idx].copyWith(posX: worldX, posY: worldY);
      });
      _send('note_move', {'id': id, 'pos_x': worldX, 'pos_y': worldY});
    }
  }

  void _ungroupNote(String id) {
    _send('note_ungroup', {'id': id});
  }

  void _deleteNote(String id) {
    _send('note_delete', {'id': id});
  }

  void _updateNote(String id, String content) {
    _send('note_update', {'id': id, 'content': content});
  }

  void _groupNotes(String draggedId, String targetId) {
    _send('note_group', {'dragged_id': draggedId, 'target_id': targetId});
  }

  int _myVotesUsed() {
    final userId = context.read<AuthProvider>().user?.id ?? '';
    return _votes.values.fold(0, (sum, m) => sum + (m[userId] ?? 0));
  }

  void _setVote(String noteId, int count) {
    final userId = context.read<AuthProvider>().user?.id ?? '';
    setState(() => _votes.putIfAbsent(noteId, () => {})[userId] = count);
    _send('vote', {'note_id': noteId, 'count': count});
  }

  bool _anyNoteVisible() {
    if (_notes.isEmpty) return true;
    final size = MediaQuery.of(context).size;
    const tabBarH = 40.0;
    final canvasH = size.height - kToolbarHeight - tabBarH;
    for (final note in _notes) {
      final sx = note.posX * _scale + _offset.dx;
      final sy = note.posY * _scale + _offset.dy;
      if (sx + _noteWidth * _scale > 0 &&
          sx < size.width &&
          sy + _noteMinHeight * _scale > 0 &&
          sy < canvasH) {
        return true;
      }
    }
    return false;
  }

  void _centerIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_anyNoteVisible()) _centerView();
    });
  }

  void _changeSlide(int i) {
    if (!_isPresenter) return;
    setState(() => _slide = i);
    _send('slide_change', {'slide': i});
    if (i == 1 || i == 2 || i == 3) _centerIfNeeded();
  }

  Future<void> _showSetPresenterDialog() async {
    if (_group == null || _project == null) return;
    final members = _group!.members;
    String? selected = _project!.presenterId;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Set Presenter'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String?>(
                  title: Text(_project!.creatorUsername != null
                      ? '${_project!.creatorUsername} (creator)'
                      : 'Project creator (default)'),
                  value: null,
                  groupValue: selected,
                  onChanged: (v) => setLocal(() => selected = v),
                ),
                ...members.map((m) => RadioListTile<String?>(
                      title: Text(m.username),
                      subtitle: Text(m.email,
                          style: const TextStyle(fontSize: 11)),
                      value: m.id,
                      groupValue: selected,
                      onChanged: (v) => setLocal(() => selected = v),
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Confirm')),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;
    try {
      final api = context.read<AuthProvider>().api;
      final updated = await api.setPresenter(
        groupSlug: widget.groupSlug,
        projectSlug: widget.projectSlug,
        userId: selected,
      );
      setState(() => _project = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  void _centerView() {
    final size = MediaQuery.of(context).size;
    if (_notes.isEmpty) {
      setState(() {
        _scale = 1.0;
        _offset = Offset(size.width / 2, size.height / 2);
      });
      return;
    }

    const padding = 48.0;
    double minX = _notes.first.posX;
    double maxX = _notes.first.posX + _noteWidth;
    double minY = _notes.first.posY;
    double maxY = _notes.first.posY + _noteMinHeight;

    for (final note in _notes) {
      minX = min(minX, note.posX);
      maxX = max(maxX, note.posX + _noteWidth);
      minY = min(minY, note.posY);
      maxY = max(maxY, note.posY + _noteMinHeight);
    }

    final worldW = maxX - minX;
    final worldH = maxY - minY;
    final scaleX = (size.width - padding * 2) / worldW;
    final scaleY = (size.height - kToolbarHeight - padding * 2) / worldH;
    final newScale = min(scaleX, scaleY).clamp(0.05, 8.0);
    final worldCx = (minX + maxX) / 2;
    final worldCy = (minY + maxY) / 2;

    setState(() {
      _scale = newScale;
      _offset = Offset(
        size.width / 2 - worldCx * newScale,
        size.height / 2 - worldCy * newScale,
      );
    });
  }

  Offset get _worldCenter {
    final size = MediaQuery.of(context).size;
    return (Offset(size.width / 2, size.height / 2) - _offset) / _scale;
  }

  Future<void> _showAddNoteDialog() async {
    final contentCtrl = TextEditingController();
    String selectedColor = _noteColors.first;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('New Sticky Note'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: contentCtrl,
                decoration: const InputDecoration(
                  labelText: 'What\'s on your mind?',
                ),
                maxLines: 4,
                autofocus: true,
              ),
              const SizedBox(height: 16),
              const Text('Colour', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 8),
              Row(
                children: _noteColors.map((c) {
                  final selected = c == selectedColor;
                  return GestureDetector(
                    onTap: () => setLocal(() => selectedColor = c),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.only(right: 8),
                      width: selected ? 34 : 28,
                      height: selected ? 34 : 28,
                      decoration: BoxDecoration(
                        color: _hexColor(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color:
                              selected ? Colors.black87 : Colors.transparent,
                          width: 2.5,
                        ),
                        boxShadow: selected
                            ? [
                                const BoxShadow(
                                    blurRadius: 4, color: Colors.black26)
                              ]
                            : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (contentCtrl.text.trim().isNotEmpty) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && mounted) {
      final center = _worldCenter;
      final posX = center.dx + (_rng.nextDouble() - 0.5) * 200;
      final posY = center.dy + (_rng.nextDouble() - 0.5) * 200;
      _send('note_create', {
        'content': contentCtrl.text.trim(),
        'color': selectedColor,
        'pos_x': posX,
        'pos_y': posY,
      });
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _gestureStartOffset = _offset;
    _gestureStartScale = _scale;
    _gestureStartFocal = d.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_isDraggingNote) return;
    setState(() {
      final newScale = (_gestureStartScale * d.scale).clamp(0.05, 8.0);
      final focalWorld =
          (_gestureStartFocal - _gestureStartOffset) / _gestureStartScale;
      _offset = d.focalPoint - focalWorld * newScale;
      _scale = newScale;
    });
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final zoomFactor = e.scrollDelta.dy > 0 ? 0.9 : 1.1;
    setState(() {
      final newScale = (_scale * zoomFactor).clamp(0.05, 8.0);
      final focalWorld = (e.localPosition - _offset) / _scale;
      _offset = e.localPosition - focalWorld * newScale;
      _scale = newScale;
    });
  }

  StickyNote? _findOverlap(String excludeId, double worldX, double worldY) {
    final cx = worldX + _noteWidth / 2;
    final cy = worldY + _noteMinHeight / 2;
    for (final note in _notes) {
      if (note.id == excludeId) continue;
      if (cx >= note.posX &&
          cx <= note.posX + _noteWidth &&
          cy >= note.posY &&
          cy <= note.posY + _noteMinHeight) {
        return note;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _psDebounce?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loginRequired) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text('Login required',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('This project does not allow guest access.',
                  style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => context.go('/auth/login'),
                child: const Text('Log in'),
              ),
            ],
          ),
        ),
      );
    }

    final isProblemMode = _slide == 0;
    final isGroupingMode = _slide == 2;
    final enableProblem = _project?.enableProblem ?? true;
    final enableVote = _project?.enableVote ?? false;
    final enablePrioritise = _project?.enablePrioritise ?? false;
    final isVotingMode = _slide == 3 && enableVote;
    final isCostValueMode = _slide == 4 && enablePrioritise;
    final isPresenter = _isPresenter;
    final canAssign = _canAssignPresenter;
    final currentUserId = context.read<AuthProvider>().user?.id ?? '';
    final presenterLabel = _project?.presenterUsername
        ?? _project?.creatorUsername
        ?? '';

    final enabledSlides = [
      if (enableProblem) 0,
      1,
      2,
      if (enableVote) 3,
      if (enablePrioritise) 4,
    ];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => context.go('/groups/${widget.groupSlug}'),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_project?.name ?? '…'),
            if (presenterLabel.isNotEmpty)
              Text(
                isPresenter ? 'You are presenting' : 'Presenter: $presenterLabel',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: isPresenter
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
        actions: [
          if (canAssign)
            IconButton(
              icon: const Icon(Icons.switch_account_outlined),
              tooltip: 'Set presenter',
              onPressed: _showSetPresenterDialog,
            ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Activity info',
            onPressed: () {
              setState(() => _dismissedInterstitials.remove(_slide));
              _saveDismissed();
            },
          ),
          IconButton(
            icon: const Icon(Icons.center_focus_strong_outlined),
            tooltip: 'Center view',
            onPressed: _centerView,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Tooltip(
              message: _connected ? 'Connected' : 'Disconnected',
              child: Icon(
                _connected ? Icons.wifi : Icons.wifi_off,
                color: _connected ? Colors.green : Colors.red,
                size: 20,
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _slide != 1 || _showInterstitial
          ? null
          : FloatingActionButton.extended(
              onPressed: _showAddNoteDialog,
              icon: const Icon(Icons.add),
              label: const Text('Add Note'),
            ),
      body: Column(
        children: [
          _SlideTabBar(
            currentSlide: _slide,
            enabled: isPresenter,
            enabledSlides: enabledSlides,
            onSlideChanged: _changeSlide,
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: isProblemMode
                      ? _ProblemStatementSlide(
                          text: _problemStatement,
                          isPresenter: isPresenter,
                          onChanged: (text) {
                            setState(() => _problemStatement = text);
                            _psDebounce?.cancel();
                            _psDebounce = Timer(
                              const Duration(milliseconds: 300),
                              () => _send('problem_statement_update', {'text': text}),
                            );
                          },
                        )
                      : isCostValueMode
                      ? _CostValueMatrix(
                          notes: _notes,
                          positions: _matrixPositions,
                          lockedBy: _matrixLockedBy,
                          currentUserId:
                              context.read<AuthProvider>().user?.id ?? '',
                          onPositionChanged: _onMatrixPositionChanged,
                          onDragStart: _onMatrixDragStart,
                          onDragEnd: _onMatrixDragEnd,
                        )
                      : isVotingMode
                          ? ClipRect(
                              child: Listener(
                                onPointerSignal: _onPointerSignal,
                                child: GestureDetector(
                                  onScaleStart: _onScaleStart,
                                  onScaleUpdate: _onScaleUpdate,
                                  child: _VoteCanvas(
                                    notes: _notes,
                                    votes: _votes,
                                    currentUserId:
                                        context.read<AuthProvider>().user?.id ?? '',
                                    starsLeft: 4 - _myVotesUsed(),
                                    offset: _offset,
                                    scale: _scale,
                                    onVoteDelta: (noteId, delta) {
                                      final userId =
                                          context.read<AuthProvider>().user?.id ?? '';
                                      final current =
                                          _votes[noteId]?[userId] ?? 0;
                                      final next = (current + delta).clamp(0, 4);
                                      if (next == current) return;
                                      _setVote(noteId, next);
                                    },
                                  ),
                                ),
                              ),
                            )
                          : ClipRect(
                              child: Listener(
                                onPointerSignal: _onPointerSignal,
                                child: GestureDetector(
                                  onScaleStart: _onScaleStart,
                                  onScaleUpdate: _onScaleUpdate,
                                  child: _InfiniteCanvas(
                                    notes: _notes,
                                    offset: _offset,
                                    scale: _scale,
                                    isGroupingMode: isGroupingMode,
                                    groupDragOffsets: _groupDragOffsets,
                                    onNoteMove: _moveNote,
                                    onNoteDelete: _deleteNote,
                                    onNoteUpdate: _updateNote,
                                    onGroupNotes: _groupNotes,
                                    onUngroupNote: _ungroupNote,
                                    onFindOverlap: _findOverlap,
                                    onGroupDragUpdate: _onGroupDragUpdate,
                                    onGroupDragEnd: _onGroupDragEnd,
                                    onNoteDragStart: () =>
                                        setState(() => _isDraggingNote = true),
                                    onNoteDragEnd: () =>
                                        setState(() => _isDraggingNote = false),
                                    currentUserId: currentUserId,
                                    isPresenter: isPresenter,
                                    isOwner: canAssign,
                                  ),
                                ),
                              ),
                            ),
                ),
                if (_showInterstitial)
                  _SlideInterstitial(
                    slide: _slide,
                    customDescription: _project?.interstitialForSlide(_slide),
                    onDismiss: () {
                      setState(() => _dismissedInterstitials.add(_slide));
                      _saveDismissed();
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Slide interstitial ───────────────────────────────────────────────────────

const _interstitials = [
  (
    icon: Icons.lightbulb_outline,
    title: 'Problem Statement',
    description:
        'As a team, define the problem you\'re solving. Be specific — a well-framed problem leads to better solutions.',
    action: 'Got it',
  ),
  (
    icon: Icons.sticky_note_2_outlined,
    title: 'Brainstorm',
    description:
        'Add as many ideas as you like using sticky notes. Quantity over quality — no idea is too small at this stage.',
    action: 'Start brainstorming',
  ),
  (
    icon: Icons.hub_outlined,
    title: 'Group',
    description:
        'Drag similar ideas onto each other to cluster them into themes. Look for patterns across the notes.',
    action: 'Start grouping',
  ),
  (
    icon: Icons.how_to_vote_outlined,
    title: 'Vote',
    description:
        'You have 4 stars to distribute. Place them on the ideas you think are most valuable to pursue.',
    action: 'Start voting',
  ),
  (
    icon: Icons.grid_view_outlined,
    title: 'Prioritise',
    description:
        'Place each idea on the matrix based on its cost to implement vs the value it delivers to the team.',
    action: 'Start prioritising',
  ),
];

class _SlideInterstitial extends StatelessWidget {
  final int slide;
  final VoidCallback onDismiss;
  final String? customDescription;

  const _SlideInterstitial({
    required this.slide,
    required this.onDismiss,
    this.customDescription,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = _interstitials[slide.clamp(0, _interstitials.length - 1)];
    final description = customDescription ?? info.description;

    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            margin: const EdgeInsets.all(32),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      info.icon,
                      size: 32,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    info.title,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    description,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onDismiss,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(info.action),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Slide tab bar ────────────────────────────────────────────────────────────

const _slideLabels = ['Problem', 'Brainstorm', 'Group', 'Vote', 'Prioritise'];
const _slideIcons = [Icons.lightbulb_outline, Icons.sticky_note_2_outlined, Icons.hub_outlined, Icons.how_to_vote_outlined, Icons.grid_view_outlined];

class _SlideTabBar extends StatelessWidget {
  final int currentSlide;
  final bool enabled;
  final List<int> enabledSlides;
  final void Function(int) onSlideChanged;

  const _SlideTabBar({
    required this.currentSlide,
    required this.enabled,
    required this.enabledSlides,
    required this.onSlideChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final idx = enabledSlides.indexOf(currentSlide);
    final prevSlide = idx > 0 ? enabledSlides[idx - 1] : null;
    final nextSlide =
        idx < enabledSlides.length - 1 ? enabledSlides[idx + 1] : null;
    final canPrev = enabled && prevSlide != null;
    final canNext = enabled && nextSlide != null;
    final showLabels = MediaQuery.of(context).size.width >= 600;

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Row(
        children: [
          // Prev arrow
          _NavArrow(
            icon: Icons.chevron_left,
            enabled: canPrev,
            onTap: canPrev ? () => onSlideChanged(prevSlide) : null,
          ),
          const SizedBox(width: 4),
          // Slide tabs — only enabled slides
          ...enabledSlides.indexed.expand((entry) {
            final (pos, i) = entry;
            return [
              _SlideTab(
                label: _slideLabels[i],
                icon: _slideIcons[i],
                selected: currentSlide == i,
                showLabel: showLabels,
                onTap: enabled ? () => onSlideChanged(i) : null,
              ),
              if (pos < enabledSlides.length - 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.chevron_right,
                      size: 14, color: theme.colorScheme.onSurfaceVariant),
                ),
            ];
          }),
          const Spacer(),
          // Slide counter (position within enabled slides)
          Text(
            '${idx + 1} / ${enabledSlides.length}',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 4),
          // Next arrow
          _NavArrow(
            icon: Icons.chevron_right,
            enabled: canNext,
            onTap: canNext ? () => onSlideChanged(nextSlide) : null,
          ),
        ],
      ),
    );
  }
}

class _NavArrow extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const _NavArrow({required this.icon, required this.enabled, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: enabled ? 1.0 : 0.3,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: enabled
                ? theme.colorScheme.surfaceContainerHighest
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _SlideTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool showLabel;
  final VoidCallback? onTap;

  const _SlideTab({
    required this.label,
    required this.icon,
    required this.selected,
    this.showLabel = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant),
            if (showLabel) ...[
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Infinite canvas ──────────────────────────────────────────────────────────

class _InfiniteCanvas extends StatelessWidget {
  final List<StickyNote> notes;
  final Offset offset;
  final double scale;
  final bool isGroupingMode;
  final Map<String, Offset> groupDragOffsets;
  final void Function(String id, double worldX, double worldY) onNoteMove;
  final void Function(String id) onNoteDelete;
  final void Function(String id, String content) onNoteUpdate;
  final void Function(String draggedId, String targetId) onGroupNotes;
  final void Function(String id) onUngroupNote;
  final StickyNote? Function(String excludeId, double worldX, double worldY)
      onFindOverlap;
  final void Function(String groupId, double dx, double dy) onGroupDragUpdate;
  final void Function(String groupId) onGroupDragEnd;
  final VoidCallback onNoteDragStart;
  final VoidCallback onNoteDragEnd;
  final String currentUserId;
  final bool isPresenter;
  final bool isOwner;

  const _InfiniteCanvas({
    required this.notes,
    required this.offset,
    required this.scale,
    required this.isGroupingMode,
    required this.groupDragOffsets,
    required this.onNoteMove,
    required this.onNoteDelete,
    required this.onNoteUpdate,
    required this.onGroupNotes,
    required this.onUngroupNote,
    required this.onFindOverlap,
    required this.onGroupDragUpdate,
    required this.onGroupDragEnd,
    required this.onNoteDragStart,
    required this.onNoteDragEnd,
    required this.currentUserId,
    required this.isPresenter,
    required this.isOwner,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _InfiniteGridPainter(
                  offset: offset,
                  scale: scale,
                  bgColor: cs.surfaceContainerHighest,
                  dotColor: cs.outline,
                ),
              ),
            ),
            if (isGroupingMode)
              Positioned.fill(
                child: CustomPaint(
                  painter: _GroupBackgroundPainter(
                      notes: notes, offset: offset, scale: scale),
                ),
              ),
            if (notes.isEmpty)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.sticky_note_2_outlined,
                        size: 72, color: cs.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text(
                        isGroupingMode
                            ? 'No notes to group yet'
                            : 'Start brainstorming!',
                        style: TextStyle(
                            fontSize: 20, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Text(
                        isGroupingMode
                            ? 'Switch to Brainstorm to add notes first'
                            : 'Tap + Add Note to place your first idea',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            // Transparent drag areas for each group container — sit below
            // individual note cards so child notes still win hit-tests in
            // their own area; background areas move the whole group.
            ...notes.where((n) => n.isGroup).expand((groupNote) {
              final children =
                  notes.where((n) => n.parentId == groupNote.id).toList();
              if (children.isEmpty) return <Widget>[];
              final all = [groupNote, ...children];
              final minX = all.map((n) => n.posX).reduce(min);
              final minY = all.map((n) => n.posY).reduce(min);
              final maxX =
                  all.map((n) => n.posX + _noteWidth).reduce(max);
              final maxY =
                  all.map((n) => n.posY + _noteMinHeight).reduce(max);
              const pad = 18.0;
              final dragOff =
                  groupDragOffsets[groupNote.id] ?? Offset.zero;
              return [
                _GroupDragArea(
                  key: ValueKey('drag_area_${groupNote.id}'),
                  groupNoteId: groupNote.id,
                  groupNotePosX: groupNote.posX,
                  groupNotePosY: groupNote.posY,
                  left: (minX - pad + dragOff.dx) * scale + offset.dx,
                  top: (minY - pad + dragOff.dy) * scale + offset.dy,
                  width: (maxX - minX + pad * 2) * scale,
                  height: (maxY - minY + pad * 2) * scale,
                  scale: scale,
                  onGroupDragUpdate: onGroupDragUpdate,
                  onGroupDragEnd: onGroupDragEnd,
                  onGroupMove: onNoteMove,
                ),
              ];
            }),
            // Child notes first, then group notes on top.
            ...[...notes.where((n) => !n.isGroup), ...notes.where((n) => n.isGroup)]
                .map((note) {
              final groupId = note.isGroup ? note.id : note.parentId;
              final dragOffset = groupId != null
                  ? (groupDragOffsets[groupId] ?? Offset.zero)
                  : Offset.zero;
              return _PositionedNote(
                key: ValueKey(note.id),
                note: note,
                canvasSize: size,
                offset: offset,
                scale: scale,
                isGroupingMode: isGroupingMode,
                dragOffset: dragOffset,
                onMove: onNoteMove,
                onDelete: onNoteDelete,
                onUpdate: onNoteUpdate,
                onFindOverlap: onFindOverlap,
                onGroupNotes: onGroupNotes,
                onUngroup: onUngroupNote,
                onGroupDragUpdate: onGroupDragUpdate,
                onGroupDragEnd: onGroupDragEnd,
                onDragStart: onNoteDragStart,
                onDragEnd: onNoteDragEnd,
                canDelete: isPresenter || isOwner || note.createdBy == currentUserId,
              );
            }),
          ],
        );
      },
    );
  }
}

// ─── Grid painter ─────────────────────────────────────────────────────────────

class _InfiniteGridPainter extends CustomPainter {
  final Offset offset;
  final double scale;
  final Color bgColor;
  final Color dotColor;

  const _InfiniteGridPainter({
    required this.offset,
    required this.scale,
    required this.bgColor,
    required this.dotColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(bgColor, BlendMode.src);

    const worldSpacing = 40.0;
    final screenSpacing = worldSpacing * scale;
    if (screenSpacing < 6) return;

    final paint = Paint()
      ..color = dotColor
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    final worldLeft = -offset.dx / scale;
    final worldTop = -offset.dy / scale;
    final worldRight = (size.width - offset.dx) / scale;
    final worldBottom = (size.height - offset.dy) / scale;

    final firstX = (worldLeft / worldSpacing).ceil() * worldSpacing;
    final firstY = (worldTop / worldSpacing).ceil() * worldSpacing;

    final points = <Offset>[];
    for (double wx = firstX; wx <= worldRight; wx += worldSpacing) {
      for (double wy = firstY; wy <= worldBottom; wy += worldSpacing) {
        points.add(Offset(wx * scale + offset.dx, wy * scale + offset.dy));
      }
    }
    if (points.isNotEmpty) {
      canvas.drawPoints(PointMode.points, points, paint);
    }
  }

  @override
  bool shouldRepaint(_InfiniteGridPainter old) =>
      old.offset != offset || old.scale != scale ||
      old.bgColor != bgColor || old.dotColor != dotColor;
}

// ─── Group background painter ─────────────────────────────────────────────────

const _groupPalette = [
  (Color(0x28A5D6A7), Color(0xFF66BB6A)),
  (Color(0x2890CAF9), Color(0xFF42A5F5)),
  (Color(0x28FFCC80), Color(0xFFFFA726)),
  (Color(0x28CE93D8), Color(0xFFAB47BC)),
  (Color(0x28F48FB1), Color(0xFFEC407A)),
  (Color(0x28FFF176), Color(0xFFFFD600)),
];

(Color, Color) _groupColors(String groupId) =>
    _groupPalette[groupId.hashCode.abs() % _groupPalette.length];

class _GroupBackgroundPainter extends CustomPainter {
  final List<StickyNote> notes;
  final Offset offset;
  final double scale;

  const _GroupBackgroundPainter(
      {required this.notes, required this.offset, required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    for (final group in notes.where((n) => n.isGroup)) {
      final children = notes.where((n) => n.parentId == group.id).toList();
      if (children.isEmpty) continue;

      final all = [group, ...children];
      double minX = all.first.posX;
      double minY = all.first.posY;
      double maxX = minX + _noteWidth;
      double maxY = minY + _noteMinHeight;

      for (final note in all) {
        minX = min(minX, note.posX);
        minY = min(minY, note.posY);
        maxX = max(maxX, note.posX + _noteWidth);
        maxY = max(maxY, note.posY + _noteMinHeight);
      }

      const padding = 18.0;
      final rect = Rect.fromLTRB(
        (minX - padding) * scale + offset.dx,
        (minY - padding) * scale + offset.dy,
        (maxX + padding) * scale + offset.dx,
        (maxY + padding) * scale + offset.dy,
      );
      final rRect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
      final (fill, border) = _groupColors(group.id);

      canvas.drawRRect(rRect, Paint()..color = fill);
      canvas.drawRRect(
          rRect,
          Paint()
            ..color = border
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_GroupBackgroundPainter old) =>
      old.notes != notes || old.offset != offset || old.scale != scale;
}

// ─── Draggable sticky note ────────────────────────────────────────────────────

const double _noteWidth = 164;
const double _noteMinHeight = 90;
const List<String> _noteColors = [
  '#FFF176',
  '#A5D6A7',
  '#F48FB1',
  '#90CAF9',
  '#FFCC80',
  '#CE93D8',
];

Color _hexColor(String hex) {
  final h = hex.replaceFirst('#', '');
  return Color(int.parse('FF$h', radix: 16));
}

class _PositionedNote extends StatefulWidget {
  final StickyNote note;
  final Size canvasSize;
  final Offset offset;
  final double scale;
  final bool isGroupingMode;
  final Offset dragOffset;
  final void Function(String id, double worldX, double worldY) onMove;
  final void Function(String id) onDelete;
  final void Function(String id, String content) onUpdate;
  final StickyNote? Function(String excludeId, double worldX, double worldY)
      onFindOverlap;
  final void Function(String draggedId, String targetId) onGroupNotes;
  final void Function(String id) onUngroup;
  final void Function(String groupId, double dx, double dy) onGroupDragUpdate;
  final void Function(String groupId) onGroupDragEnd;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final bool canDelete;

  const _PositionedNote({
    super.key,
    required this.note,
    required this.canvasSize,
    required this.offset,
    required this.scale,
    required this.isGroupingMode,
    required this.dragOffset,
    required this.onMove,
    required this.onDelete,
    required this.onUpdate,
    required this.onFindOverlap,
    required this.onGroupNotes,
    required this.onUngroup,
    required this.onGroupDragUpdate,
    required this.onGroupDragEnd,
    required this.onDragStart,
    required this.onDragEnd,
    required this.canDelete,
  });

  @override
  State<_PositionedNote> createState() => _PositionedNoteState();
}

class _PositionedNoteState extends State<_PositionedNote> {
  late double _worldX;
  late double _worldY;
  bool _isDragging = false;
  bool _isEditing = false;
  late TextEditingController _editCtrl;
  late FocusNode _editFocusNode;

  @override
  void initState() {
    super.initState();
    _worldX = widget.note.posX;
    _worldY = widget.note.posY;
    _editCtrl = TextEditingController(text: widget.note.content);
    _editFocusNode = FocusNode();
    _editFocusNode.addListener(() {
      if (!_editFocusNode.hasFocus && _isEditing) {
        _commitEdit();
      }
    });
  }

  @override
  void didUpdateWidget(_PositionedNote old) {
    super.didUpdateWidget(old);
    if (!_isDragging) {
      _worldX = widget.note.posX;
      _worldY = widget.note.posY;
    }
    if (!_isEditing) {
      _editCtrl.text = widget.note.content;
    }
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  void _commitEdit() {
    if (!_isEditing) return;
    setState(() => _isEditing = false);
    if (_editCtrl.text != widget.note.content) {
      widget.onUpdate(widget.note.id, _editCtrl.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Apply the group drag offset to non-dragged members so they move together.
    final extra = _isDragging ? Offset.zero : widget.dragOffset;
    final screenX = (_worldX + extra.dx) * widget.scale + widget.offset.dx;
    final screenY = (_worldY + extra.dy) * widget.scale + widget.offset.dy;

    return Positioned(
      left: screenX,
      top: screenY,
      child: Transform.scale(
        scale: widget.scale,
        alignment: Alignment.topLeft,
        child: GestureDetector(
          onPanStart: (_) {
            setState(() => _isDragging = true);
            widget.onDragStart();
          },
          onPanUpdate: (d) {
            // d.delta is already in local (world) coordinates because this
            // GestureDetector is inside Transform.scale(scale: widget.scale).
            // Dividing by scale again would make dragging lag at high zoom.
            setState(() {
              _worldX += d.delta.dx;
              _worldY += d.delta.dy;
            });
            if (widget.note.isGroup) {
              widget.onGroupDragUpdate(widget.note.id, d.delta.dx, d.delta.dy);
            }
          },
          onPanEnd: (_) {
            // onMove first: optimistically updates parent state while
            // _isDragging is still true, so didUpdateWidget won't snap the
            // note back to the old position when we rebuild below.
            widget.onMove(widget.note.id, _worldX, _worldY);
            if (widget.note.isGroup) {
              widget.onGroupDragEnd(widget.note.id);
            } else if (widget.note.parentId != null) {
              // Child note: can leave group in any mode.
              final target =
                  widget.onFindOverlap(widget.note.id, _worldX, _worldY);
              if (target != null && widget.isGroupingMode) {
                widget.onGroupNotes(widget.note.id, target.id);
              } else if (target == null) {
                widget.onUngroup(widget.note.id);
              }
            } else if (widget.isGroupingMode) {
              // Ungrouped note in grouping mode: can join a group.
              final target =
                  widget.onFindOverlap(widget.note.id, _worldX, _worldY);
              if (target != null) {
                widget.onGroupNotes(widget.note.id, target.id);
              }
            }
            setState(() => _isDragging = false);
            widget.onDragEnd();
          },
          onDoubleTap: () {
            setState(() => _isEditing = true);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _editFocusNode.requestFocus();
            });
          },
          child: _NoteCard(
            note: widget.note,
            isGroupingMode: widget.isGroupingMode,
            onDelete: () => widget.onDelete(widget.note.id),
            showActions: widget.canDelete,
            isEditing: _isEditing,
            editController: _editCtrl,
            editFocusNode: _editFocusNode,
            onEditDone: _commitEdit,
          ),
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final StickyNote note;
  final bool isGroupingMode;
  final VoidCallback onDelete;
  final bool isEditing;
  final bool showActions;
  final TextEditingController? editController;
  final FocusNode? editFocusNode;
  final VoidCallback? onEditDone;

  const _NoteCard({
    required this.note,
    required this.isGroupingMode,
    required this.onDelete,
    this.isEditing = false,
    this.showActions = true,
    this.editController,
    this.editFocusNode,
    this.onEditDone,
  });

  @override
  Widget build(BuildContext context) {
    if (note.isGroup) {
      return _buildGroupCard(context);
    }

    final bg = _hexColor(note.color);
    final isDark =
        ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtleColor = isDark ? Colors.white60 : Colors.black38;
    final isChild = note.parentId != null;

    return Material(
      elevation: isChild ? 2 : 6,
      borderRadius: BorderRadius.circular(3),
      color: bg,
      shadowColor: Colors.black38,
      child: SizedBox(
        width: _noteWidth,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 28, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  isEditing
                      ? TextField(
                          controller: editController,
                          focusNode: editFocusNode,
                          autofocus: true,
                          maxLines: null,
                          style: TextStyle(
                            fontSize: 13,
                            color: textColor,
                            height: 1.45,
                            fontFamily: 'monospace',
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            border: InputBorder.none,
                          ),
                          onSubmitted: (_) => onEditDone?.call(),
                        )
                      : MarkdownBody(
                          data: note.content,
                          styleSheet: MarkdownStyleSheet(
                            p: TextStyle(
                              fontSize: 13,
                              color: textColor,
                              height: 1.45,
                            ),
                            strong: TextStyle(
                              fontSize: 13,
                              color: textColor,
                              fontWeight: FontWeight.bold,
                            ),
                            em: TextStyle(
                              fontSize: 13,
                              color: textColor,
                              fontStyle: FontStyle.italic,
                            ),
                            code: TextStyle(
                              fontSize: 12,
                              color: textColor,
                              fontFamily: 'monospace',
                              backgroundColor: Colors.black12,
                            ),
                            listBullet: TextStyle(
                              fontSize: 13,
                              color: textColor,
                            ),
                          ),
                        ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.person_outline,
                          size: 11, color: subtleColor),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          note.author,
                          style:
                              TextStyle(fontSize: 11, color: subtleColor),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isChild && isGroupingMode) ...[
                        const SizedBox(width: 4),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _groupColors(note.parentId!).$2,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (showActions)
              Positioned(
                top: 3,
                right: 3,
                child: GestureDetector(
                  onTap: onDelete,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    child: Icon(Icons.close, size: 14, color: subtleColor),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupCard(BuildContext context) {
    final (fill, border) = _groupColors(note.id);
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(6),
      color: Theme.of(context).colorScheme.surface,
      shadowColor: Colors.black26,
      child: Container(
        width: _noteWidth,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border, width: 2),
        ),
        child: Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(4)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.hub_outlined, size: 12, color: border),
                      const SizedBox(width: 4),
                      Text(
                        'Group',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: border,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 28, 10),
                  child: isEditing
                      ? TextField(
                          controller: editController,
                          focusNode: editFocusNode,
                          autofocus: true,
                          maxLines: null,
                          style: const TextStyle(fontSize: 13, height: 1.45),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            border: InputBorder.none,
                          ),
                          onSubmitted: (_) => onEditDone?.call(),
                        )
                      : Text(
                          note.content.isEmpty ? 'Untitled group' : note.content,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: note.content.isEmpty
                                ? Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
                                : Theme.of(context).colorScheme.onSurface,
                            fontStyle: note.content.isEmpty
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                ),
              ],
            ),
            if (showActions)
              Positioned(
                top: 3,
                right: 3,
                child: GestureDetector(
                  onTap: onDelete,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    child: Icon(Icons.close, size: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Group drag area ───────────────────────────────────────────────────────────
// Transparent hit-target that covers a group's bounding box. Sits below
// individual note cards in the Stack so child notes win in their own area,
// but captures drags on the background to move the whole group.

class _GroupDragArea extends StatefulWidget {
  final String groupNoteId;
  final double groupNotePosX;
  final double groupNotePosY;
  final double left;
  final double top;
  final double width;
  final double height;
  final double scale;
  final void Function(String groupId, double dx, double dy) onGroupDragUpdate;
  final void Function(String groupId) onGroupDragEnd;
  final void Function(String id, double worldX, double worldY) onGroupMove;

  const _GroupDragArea({
    super.key,
    required this.groupNoteId,
    required this.groupNotePosX,
    required this.groupNotePosY,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.scale,
    required this.onGroupDragUpdate,
    required this.onGroupDragEnd,
    required this.onGroupMove,
  });

  @override
  State<_GroupDragArea> createState() => _GroupDragAreaState();
}

class _GroupDragAreaState extends State<_GroupDragArea> {
  double _dx = 0;
  double _dy = 0;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.left,
      top: widget.top,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) {
          final ddx = d.delta.dx / widget.scale;
          final ddy = d.delta.dy / widget.scale;
          _dx += ddx;
          _dy += ddy;
          widget.onGroupDragUpdate(widget.groupNoteId, ddx, ddy);
        },
        onPanEnd: (_) {
          widget.onGroupMove(
            widget.groupNoteId,
            widget.groupNotePosX + _dx,
            widget.groupNotePosY + _dy,
          );
          widget.onGroupDragEnd(widget.groupNoteId);
          _dx = 0;
          _dy = 0;
        },
        child: SizedBox(width: widget.width, height: widget.height),
      ),
    );
  }
}

// ─── Problem statement slide ───────────────────────────────────────────────────

// Renders problem statement text with bold/italic/underline/strikethrough.
// Shares the same regex as _ProblemTextController for consistency.
class _ProblemRichText extends StatelessWidget {
  final String text;
  const _ProblemRichText({required this.text});

  static const _base = TextStyle(fontSize: 36, height: 1.6);

  List<InlineSpan> _parse(String text, TextStyle base) {
    final spans = <InlineSpan>[];
    int last = 0;
    for (final match in _ProblemTextController._styleRegex.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start), style: base));
      }
      if (match.group(1) != null) {
        spans.add(TextSpan(text: match.group(1), style: base.copyWith(fontWeight: FontWeight.bold)));
      } else if (match.group(2) != null) {
        spans.add(TextSpan(text: match.group(2), style: base.copyWith(decoration: TextDecoration.lineThrough)));
      } else if (match.group(3) != null) {
        spans.add(TextSpan(text: match.group(3), style: base.copyWith(decoration: TextDecoration.underline)));
      } else if (match.group(4) != null) {
        spans.add(TextSpan(text: match.group(4), style: base.copyWith(fontStyle: FontStyle.italic)));
      }
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: base));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final base = _base.copyWith(color: Theme.of(context).colorScheme.onSurface);
    return RichText(text: TextSpan(children: _parse(text, base)));
  }
}

class _ProblemTextController extends TextEditingController {
  _ProblemTextController({super.text});

  // Group 1=bold(**), 2=strikethrough(~~), 3=underline(__), 4=italic(*).
  // Bold before italic so **text** is never mis-parsed as italic.
  static final _styleRegex = RegExp(
    r'\*\*([^*]+)\*\*|~~(.+?)~~|__(.+?)__|\*([^*]+)\*',
    dotAll: true,
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = this.text;
    final spans = <InlineSpan>[];
    int last = 0;

    final hidden = style?.copyWith(fontSize: 0.001, color: Colors.transparent) ??
        const TextStyle(fontSize: 0.001, color: Colors.transparent);

    for (final match in _styleRegex.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start), style: style));
      }

      if (match.group(1) != null) {
        // Bold
        spans.add(TextSpan(text: '**', style: hidden));
        spans.add(TextSpan(text: match.group(1), style: style?.copyWith(fontWeight: FontWeight.bold)));
        spans.add(TextSpan(text: '**', style: hidden));
      } else if (match.group(2) != null) {
        // Strikethrough
        spans.add(TextSpan(text: '~~', style: hidden));
        spans.add(TextSpan(text: match.group(2), style: style?.copyWith(decoration: TextDecoration.lineThrough)));
        spans.add(TextSpan(text: '~~', style: hidden));
      } else if (match.group(3) != null) {
        // Underline
        spans.add(TextSpan(text: '__', style: hidden));
        spans.add(TextSpan(text: match.group(3), style: style?.copyWith(decoration: TextDecoration.underline)));
        spans.add(TextSpan(text: '__', style: hidden));
      } else if (match.group(4) != null) {
        // Italic
        spans.add(TextSpan(text: '*', style: hidden));
        spans.add(TextSpan(text: match.group(4), style: style?.copyWith(fontStyle: FontStyle.italic)));
        spans.add(TextSpan(text: '*', style: hidden));
      }

      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: style));
    }
    return TextSpan(children: spans, style: style);
  }
}

class _ProblemToolbar extends StatefulWidget {
  final TextEditingController ctrl;
  final void Function(String) onChanged;

  const _ProblemToolbar({required this.ctrl, required this.onChanged});

  @override
  State<_ProblemToolbar> createState() => _ProblemToolbarState();
}

class _ProblemToolbarState extends State<_ProblemToolbar> {
  bool _showEmoji = false;

  void _wrapSelection(String marker) {
    final sel = widget.ctrl.selection;
    if (!sel.isValid) return;
    final text = widget.ctrl.text;
    final selected = sel.textInside(text);
    final replacement = '$marker$selected$marker';
    final newText = text.replaceRange(sel.start, sel.end, replacement);
    final newOffset = sel.isCollapsed
        ? sel.start + marker.length
        : sel.end + marker.length * 2;
    widget.ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
    widget.onChanged(newText);
  }

  void _insertEmoji(String emoji) {
    final ctrl = widget.ctrl;
    final sel = ctrl.selection;
    final text = ctrl.text;
    final pos = sel.isValid ? sel.baseOffset : text.length;
    final end = sel.isValid ? sel.extentOffset : pos;
    final newText = text.replaceRange(pos, end, emoji);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: pos + emoji.length),
    );
    widget.onChanged(newText);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _ToolbarButton(
              label: 'B',
              bold: true,
              tooltip: 'Bold',
              onPressed: () => _wrapSelection('**'),
            ),
            const SizedBox(width: 6),
            _ToolbarButton(
              label: 'U',
              underline: true,
              tooltip: 'Underline',
              onPressed: () => _wrapSelection('__'),
            ),
            const SizedBox(width: 6),
            _ToolbarButton(
              label: 'I',
              italic: true,
              tooltip: 'Italic',
              onPressed: () => _wrapSelection('*'),
            ),
            const SizedBox(width: 6),
            _ToolbarButton(
              label: 'S',
              strikethrough: true,
              tooltip: 'Strikethrough',
              onPressed: () => _wrapSelection('~~'),
            ),
            const SizedBox(width: 6),
            _ToolbarButton(
              label: '😊',
              tooltip: 'Emoji',
              active: _showEmoji,
              onPressed: () => setState(() => _showEmoji = !_showEmoji),
            ),
          ],
        ),
        if (_showEmoji) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 280,
            child: EmojiPicker(
              onEmojiSelected: (_, emoji) => _insertEmoji(emoji.emoji),
              config: Config(
                height: 280,
                checkPlatformCompatibility: true,
                emojiViewConfig: EmojiViewConfig(
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  columns: 10,
                ),
                categoryViewConfig: CategoryViewConfig(
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  indicatorColor: Theme.of(context).colorScheme.primary,
                  iconColorSelected: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final String label;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final bool active;
  final String tooltip;
  final VoidCallback onPressed;

  const _ToolbarButton({
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? cs.primaryContainer : cs.surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
                color: active ? cs.primary : cs.outline),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: bold ? FontWeight.w800 : FontWeight.normal,
              fontStyle: italic ? FontStyle.italic : FontStyle.normal,
              decoration: underline
                  ? TextDecoration.underline
                  : strikethrough
                      ? TextDecoration.lineThrough
                      : TextDecoration.none,
              color: cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProblemStatementSlide extends StatefulWidget {
  final String text;
  final bool isPresenter;
  final void Function(String) onChanged;

  const _ProblemStatementSlide({
    required this.text,
    required this.isPresenter,
    required this.onChanged,
  });

  @override
  State<_ProblemStatementSlide> createState() => _ProblemStatementSlideState();
}

class _ProblemStatementSlideState extends State<_ProblemStatementSlide> {
  late final _ProblemTextController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = _ProblemTextController(text: widget.text);
  }

  @override
  void didUpdateWidget(_ProblemStatementSlide old) {
    super.didUpdateWidget(old);
    // Sync whenever the incoming text differs from the controller.
    // Echo-back from the server is a no-op: by the time it arrives the
    // presenter has already updated _ctrl, so the texts match.
    if (widget.text != _ctrl.text) {
      _ctrl.value = _ctrl.value.copyWith(text: widget.text);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      color: theme.scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.lightbulb_outline, size: 20, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Problem Statement',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    if (!widget.isPresenter) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Read only',
                          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                if (widget.isPresenter) ...[
                  _ProblemToolbar(ctrl: _ctrl, onChanged: widget.onChanged),
                  const SizedBox(height: 8),
                ],
                Expanded(
                  child: widget.isPresenter
                      ? TextField(
                          controller: _ctrl,
                          maxLines: null,
                          expands: true,
                          textAlignVertical: TextAlignVertical.top,
                          style: TextStyle(
                              fontSize: 36, height: 1.6, color: cs.onSurface),
                          decoration: InputDecoration(
                            hintText:
                                'Describe the problem you\'re trying to solve…',
                            hintStyle: TextStyle(
                                color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                                fontSize: 36),
                            filled: true,
                            fillColor: cs.surface,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: cs.outline),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: cs.outline),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: cs.primary),
                            ),
                            contentPadding: const EdgeInsets.all(20),
                          ),
                          onChanged: widget.onChanged,
                        )
                      : Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: cs.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: cs.outline),
                          ),
                          child: widget.text.isEmpty
                              ? Text(
                                  'No problem statement defined yet.',
                                  style: TextStyle(
                                      fontSize: 36,
                                      color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                                      fontStyle: FontStyle.italic),
                                )
                              : _ProblemRichText(text: widget.text),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Cost-value matrix ─────────────────────────────────────────────────────────

class _CostValueMatrix extends StatefulWidget {
  final List<StickyNote> notes;
  final Map<String, Offset> positions;
  final Map<String, String> lockedBy;
  final String currentUserId;
  final void Function(String id, Offset normalized) onPositionChanged;
  final void Function(String id) onDragStart;
  final void Function(String id) onDragEnd;

  const _CostValueMatrix({
    required this.notes,
    required this.positions,
    required this.lockedBy,
    required this.currentUserId,
    required this.onPositionChanged,
    required this.onDragStart,
    required this.onDragEnd,
  });

  @override
  State<_CostValueMatrix> createState() => _CostValueMatrixState();
}

class _CostValueMatrixState extends State<_CostValueMatrix> {
  final _stackKey = GlobalKey();
  double _matrixLeft = 0, _matrixTop = 0, _matrixW = 1, _matrixH = 1;
  final Map<String, Offset> _grabOffset = {};

  Offset _posFor(String id) => widget.positions[id] ?? const Offset(0.5, 0.5);

  Color _dotColor(StickyNote note) =>
      note.isGroup ? _groupColors(note.id).$2 : _hexColor(note.color);

  Offset _globalToNormalized(Offset globalPos) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return const Offset(0.5, 0.5);
    final local = box.globalToLocal(globalPos);
    return Offset(
      ((local.dx - _matrixLeft) / _matrixW).clamp(0.0, 1.0),
      (1.0 - (local.dy - _matrixTop) / _matrixH).clamp(0.0, 1.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.notes.where((n) => n.isGroup || n.parentId == null).toList();

    if (items.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_view_outlined, size: 72, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No notes yet',
                style: TextStyle(fontSize: 20, color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text('Add notes in the Brainstorm slide first',
                style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }

    final isMobile = MediaQuery.of(context).size.width < 600;

    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Left list ──────────────────────────────────────────────────────
        if (!isMobile) Container(
          width: 220,
          decoration: BoxDecoration(
            color: cs.surface,
            border: Border(right: BorderSide(color: cs.outline)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                child: Text(
                  'ITEMS',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurfaceVariant,
                      letterSpacing: 0.8),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  children: items.map((note) {
                    final color = _dotColor(note);
                    final childCount = note.isGroup
                        ? widget.notes.where((n) => n.parentId == note.id).length
                        : 0;
                    final label = note.content.isEmpty
                        ? (note.isGroup ? 'Untitled group' : '')
                        : note.content;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: note.isGroup
                                  ? _groupColors(note.id).$1
                                  : color,
                              border: Border.all(color: color, width: 2),
                            ),
                            child: note.isGroup
                                ? Center(
                                    child: Icon(Icons.hub_outlined,
                                        size: 10, color: color))
                                : null,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  style: TextStyle(
                                      fontSize: 12, color: cs.onSurface),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (note.isGroup && childCount > 0)
                                  Text(
                                    '$childCount item${childCount == 1 ? '' : 's'}',
                                    style: TextStyle(
                                        fontSize: 10, color: cs.onSurfaceVariant),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
        // ── Matrix area ────────────────────────────────────────────────────
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            const leftPad = 40.0;
            const bottomPad = 40.0;
            const outerPad = 16.0;
            const matrixLeft = leftPad + outerPad;
            const matrixTop = outerPad;
            final matrixRight = constraints.maxWidth - outerPad;
            final matrixBottom = constraints.maxHeight - bottomPad - outerPad;
            final matrixW = matrixRight - matrixLeft;
            final matrixH = matrixBottom - matrixTop;

            _matrixLeft = matrixLeft;
            _matrixTop = matrixTop;
            _matrixW = matrixW;
            _matrixH = matrixH;

            Offset toScreen(Offset norm) => Offset(
                  matrixLeft + norm.dx * matrixW,
                  matrixTop + (1.0 - norm.dy) * matrixH,
                );

            final isDarkMode = Theme.of(context).brightness == Brightness.dark;
            return Stack(key: _stackKey, children: [
              // Background fill
              Positioned.fill(
                  child: Container(color: Theme.of(context).scaffoldBackgroundColor)),
              // Quadrant grid
              Positioned(
                left: matrixLeft,
                top: matrixTop,
                width: matrixW,
                height: matrixH,
                child: CustomPaint(painter: _MatrixPainter(isDark: isDarkMode)),
              ),
              // Y-axis label
              Positioned(
                left: 0,
                top: matrixTop,
                width: leftPad,
                height: matrixH,
                child: Center(
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Text('Value  →',
                        style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w500)),
                  ),
                ),
              ),
              // X-axis label
              Positioned(
                left: matrixLeft,
                top: matrixBottom + 8,
                width: matrixW,
                height: bottomPad,
                child: Center(
                  child: Text('Cost  →',
                      style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w500)),
                ),
              ),
              // Axis endpoint labels
              Positioned(
                left: matrixLeft + 4,
                top: matrixBottom + 4,
                child: Text('Low',
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ),
              Positioned(
                right: outerPad + 4,
                top: matrixBottom + 4,
                child: Text('High',
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ),
              Positioned(
                left: 4,
                top: matrixBottom - 14,
                child: Text('Low',
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ),
              Positioned(
                left: 4,
                top: matrixTop + 2,
                child: Text('High',
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ),
              // Quadrant labels
              Positioned(
                left: matrixLeft + 10,
                top: matrixTop + 10,
                child: _quadrantChip('Quick Wins', Icons.star_outline,
                    const Color(0xFF2E7D32)),
              ),
              Positioned(
                left: matrixLeft + matrixW / 2 + 10,
                top: matrixTop + 10,
                child: _quadrantChip('Strategic', Icons.trending_up,
                    const Color(0xFF1565C0)),
              ),
              Positioned(
                left: matrixLeft + 10,
                top: matrixTop + matrixH / 2 + 10,
                child: _quadrantChip('Fill-ins', Icons.low_priority,
                    const Color(0xFF6D4C41)),
              ),
              Positioned(
                left: matrixLeft + matrixW / 2 + 10,
                top: matrixTop + matrixH / 2 + 10,
                child: _quadrantChip('Time Sinks',
                    Icons.do_not_disturb_outlined, const Color(0xFFC62828)),
              ),
              // Circles
              ...items.map((note) {
                final pos = toScreen(_posFor(note.id));
                final color = _dotColor(note);
                const r = 18.0;
                final isDark =
                    ThemeData.estimateBrightnessForColor(color) ==
                        Brightness.dark;
                final iconColor = isDark ? Colors.white70 : Colors.white;
                final lockedByOther = widget.lockedBy.containsKey(note.id) &&
                    widget.lockedBy[note.id] != widget.currentUserId;

                return Positioned(
                  left: pos.dx - r,
                  top: pos.dy - r - 10,
                  child: Opacity(
                    opacity: lockedByOther ? 0.35 : 1.0,
                    child: GestureDetector(
                      onPanStart: lockedByOther
                          ? null
                          : (d) {
                              final ptrNorm =
                                  _globalToNormalized(d.globalPosition);
                              _grabOffset[note.id] =
                                  ptrNorm - _posFor(note.id);
                              widget.onDragStart(note.id);
                            },
                      onPanUpdate: lockedByOther
                          ? null
                          : (d) {
                              final ptrNorm =
                                  _globalToNormalized(d.globalPosition);
                              final grab =
                                  _grabOffset[note.id] ?? Offset.zero;
                              widget.onPositionChanged(
                                note.id,
                                Offset(
                                  (ptrNorm.dx - grab.dx).clamp(0.0, 1.0),
                                  (ptrNorm.dy - grab.dy).clamp(0.0, 1.0),
                                ),
                              );
                            },
                      onPanEnd: lockedByOther
                          ? null
                          : (_) {
                              _grabOffset.remove(note.id);
                              widget.onDragEnd(note.id);
                            },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: r * 2,
                            height: r * 2,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: color,
                              boxShadow: const [
                                BoxShadow(
                                    color: Colors.black26,
                                    blurRadius: 4,
                                    offset: Offset(0, 2))
                              ],
                            ),
                            child: Center(
                              child: note.isGroup
                                  ? Icon(Icons.hub_outlined,
                                      size: 14, color: iconColor)
                                  : Icon(Icons.sticky_note_2_outlined,
                                      size: 13, color: iconColor),
                            ),
                          ),
                          const SizedBox(height: 3),
                          SizedBox(
                            width: 72,
                            child: Text(
                              note.content.isEmpty ? '—' : note.content,
                              style: TextStyle(
                                  fontSize: 9, color: cs.onSurfaceVariant),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ]);
          }),
        ),
      ],
    );
  }

  Widget _quadrantChip(String label, IconData icon, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color.withValues(alpha: 0.55)),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }
}

class _MatrixPainter extends CustomPainter {
  final bool isDark;
  const _MatrixPainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final half = Size(size.width / 2, size.height / 2);
    // Quadrant fills — muted in dark mode
    final q1 = isDark ? const Color(0xFF1B3A1F) : const Color(0xFFE8F5E9);
    final q2 = isDark ? const Color(0xFF0D2744) : const Color(0xFFE3F2FD);
    final q3 = isDark ? const Color(0xFF2A1F14) : const Color(0xFFFFF8E1);
    final q4 = isDark ? const Color(0xFF3A0F0F) : const Color(0xFFFFEBEE);
    canvas.drawRect(Rect.fromLTWH(0, 0, half.width, half.height),
        Paint()..color = q1);
    canvas.drawRect(
        Rect.fromLTWH(half.width, 0, half.width, half.height),
        Paint()..color = q2);
    canvas.drawRect(
        Rect.fromLTWH(0, half.height, half.width, half.height),
        Paint()..color = q3);
    canvas.drawRect(
        Rect.fromLTWH(half.width, half.height, half.width, half.height),
        Paint()..color = q4);

    final borderColor = isDark ? const Color(0xFF3A3A55) : const Color(0xFFBBBBBB);
    final border = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), border);

    final dividerColor = isDark ? const Color(0xFF555566) : const Color(0xFF999999);
    final divider = Paint()
      ..color = dividerColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawLine(
        Offset(half.width, 0), Offset(half.width, size.height), divider);
    canvas.drawLine(
        Offset(0, half.height), Offset(size.width, half.height), divider);
  }

  @override
  bool shouldRepaint(_MatrixPainter old) => old.isDark != isDark;
}

// ─── Vote canvas ───────────────────────────────────────────────────────────────

class _VoteCanvas extends StatelessWidget {
  final List<StickyNote> notes;
  final Map<String, Map<String, int>> votes;
  final String currentUserId;
  final int starsLeft;
  final Offset offset;
  final double scale;
  final void Function(String noteId, int delta) onVoteDelta;

  const _VoteCanvas({
    required this.notes,
    required this.votes,
    required this.currentUserId,
    required this.starsLeft,
    required this.offset,
    required this.scale,
    required this.onVoteDelta,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _InfiniteGridPainter(
              offset: offset,
              scale: scale,
              bgColor: cs.surfaceContainerHighest,
              dotColor: cs.outline,
            ),
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _GroupBackgroundPainter(
                notes: notes, offset: offset, scale: scale),
          ),
        ),
        if (notes.isEmpty)
          Center(
            child: Builder(builder: (context) {
              final cs = Theme.of(context).colorScheme;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.how_to_vote_outlined,
                      size: 72, color: cs.onSurfaceVariant),
                  const SizedBox(height: 16),
                  Text('No notes to vote on yet',
                      style:
                          TextStyle(fontSize: 20, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Text('Add notes in Brainstorm and group them first',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                ],
              );
            }),
          ),
        // Child notes first, then group notes on top (same z-order as canvas).
        ...[...notes.where((n) => !n.isGroup), ...notes.where((n) => n.isGroup)]
            .map((note) => _VotePositionedNote(
                  key: ValueKey('vote_${note.id}'),
                  note: note,
                  offset: offset,
                  scale: scale,
                  noteVotes: votes[note.id] ?? {},
                  currentUserId: currentUserId,
                  starsLeft: starsLeft,
                  onVoteDelta: (delta) => onVoteDelta(note.id, delta),
                )),
        _StarTray(starsLeft: starsLeft),
      ],
    );
  }
}

class _VotePositionedNote extends StatelessWidget {
  final StickyNote note;
  final Offset offset;
  final double scale;
  final Map<String, int> noteVotes;
  final String currentUserId;
  final int starsLeft;
  final void Function(int delta) onVoteDelta;

  const _VotePositionedNote({
    super.key,
    required this.note,
    required this.offset,
    required this.scale,
    required this.noteVotes,
    required this.currentUserId,
    required this.starsLeft,
    required this.onVoteDelta,
  });

  @override
  Widget build(BuildContext context) {
    final screenX = note.posX * scale + offset.dx;
    final screenY = note.posY * scale + offset.dy;
    final myVotes = noteVotes[currentUserId] ?? 0;
    final totalVotes = noteVotes.values.fold(0, (a, b) => a + b);

    return Positioned(
      left: screenX,
      top: screenY,
      child: Transform.scale(
        scale: scale,
        alignment: Alignment.topLeft,
        child: DragTarget<bool>(
          onWillAcceptWithDetails: (_) => starsLeft > 0,
          onAcceptWithDetails: (_) => onVoteDelta(1),
          builder: (context, candidateData, _) {
            final isHovered = candidateData.isNotEmpty;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: isHovered
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.amber.withValues(alpha: 0.6),
                              blurRadius: 14,
                              spreadRadius: 3,
                            ),
                          ],
                        )
                      : null,
                  child: _NoteCard(
                    note: note,
                    isGroupingMode: false,
                    showActions: false,
                    onDelete: () {},
                  ),
                ),
                if (totalVotes > 0)
                  Positioned(
                    top: -10,
                    right: -10,
                    child: GestureDetector(
                      onTap: myVotes > 0 ? () => onVoteDelta(-1) : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: myVotes > 0
                              ? Colors.amber[700]
                              : Colors.grey[500],
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: const [
                            BoxShadow(blurRadius: 4, color: Colors.black26),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star,
                                size: 11, color: Colors.white),
                            const SizedBox(width: 2),
                            Text(
                              '$totalVotes',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StarTray extends StatelessWidget {
  final int starsLeft;

  const _StarTray({required this.starsLeft});

  @override
  Widget build(BuildContext context) {
    const total = 4;
    final cs = Theme.of(context).colorScheme;
    return Positioned(
      bottom: 20,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                blurRadius: 12,
                color: Colors.black.withValues(alpha: 0.15),
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Drag to vote  ',
                style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500),
              ),
              ...List.generate(total, (i) {
                final isAvailable = i < starsLeft;
                final star = Icon(
                  Icons.star_rounded,
                  color: isAvailable ? Colors.amber : cs.outline,
                  size: 32,
                );
                if (!isAvailable) return star;
                return Draggable<bool>(
                  data: true,
                  feedback: Material(
                    color: Colors.transparent,
                    child: const Icon(Icons.star_rounded,
                        color: Colors.amber, size: 38),
                  ),
                  childWhenDragging: Icon(Icons.star_outline_rounded,
                      color: cs.outline, size: 32),
                  child: star,
                );
              }),
              const SizedBox(width: 6),
              Text(
                '$starsLeft / $total',
                style:
                    TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
