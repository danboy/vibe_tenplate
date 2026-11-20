import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show ImageFilter, PointMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/group.dart';
import '../models/brainstorm.dart';
import '../models/sticky_note.dart';
import '../models/action_item.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';

class BrainstormSlideshowScreen extends StatefulWidget {
  final String groupSlug;
  final String brainstormSlug;

  const BrainstormSlideshowScreen({
    super.key,
    required this.groupSlug,
    required this.brainstormSlug,
  });

  @override
  State<BrainstormSlideshowScreen> createState() =>
      _BrainstormSlideshowScreenState();
}

class _BrainstormSlideshowScreenState extends State<BrainstormSlideshowScreen> {
  WebSocketChannel? _channel;
  List<StickyNote> _notes = [];
  List<ActionItem> _actionItems = [];
  bool _connected = false;
  int _connectedCount = 0;
  final _rng = Random();
  Brainstorm? _brainstorm;
  Group? _group;
  bool _loginRequired = false;
  bool _isGuest = false;
  String? _guestUserId;
  String _guestDisplayName = '';

  // The current user's id, whether authenticated or a guest — AuthProvider
  // is never populated for guest sessions, so ownership checks (blur, vote,
  // delete) must fall back to the guest id issued at join time.
  String get _myUserId => _isGuest
      ? (_guestUserId ?? '')
      : (context.read<AuthProvider>().user?.id ?? '');

  // 0 = problem, 1 = brainstorm, 2 = group, 3 = vote, 4 = prioritise
  int _slide = 0;
  String _problemStatement = '';
  Timer? _psDebounce;
  bool _wsInitialized = false;

  // Presenter-controlled blur of other participants' sticky notes during
  // the brainstorm step. Synced via WS so it applies for every viewer.
  bool _blurNotes = false;

  // Retro step-1 countdown timer. endsAt is only meaningful while running;
  // remainingSeconds holds the paused/reset value otherwise. _timerTicker
  // just forces a rebuild once a second so the displayed countdown moves —
  // the authoritative state always lives on the server.
  int _timerDurationSeconds = 0;
  bool _timerRunning = false;
  DateTime? _timerEndsAt;
  int _timerRemainingSeconds = 0;
  Timer? _timerTicker;

  int get _timerSecondsLeft {
    if (_timerRunning && _timerEndsAt != null) {
      return _timerEndsAt!
          .difference(DateTime.now())
          .inSeconds
          .clamp(0, _timerDurationSeconds);
    }
    return _timerRemainingSeconds;
  }

  void _applyTimerState(Map<String, dynamic> t) {
    _timerDurationSeconds = (t['duration_seconds'] as num?)?.toInt() ?? 0;
    _timerRunning = t['running'] as bool? ?? false;
    final endsAt = t['ends_at'] as String?;
    _timerEndsAt = endsAt == null ? null : DateTime.parse(endsAt);
    _timerRemainingSeconds = (t['remaining_seconds'] as num?)?.toInt() ?? 0;
    _timerTicker?.cancel();
    if (_timerRunning) {
      _timerTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _startTimer() => _send('timer_start', {});
  void _pauseTimer() => _send('timer_pause', {});
  void _resetTimer() => _send('timer_reset', {});
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
    _send('matrix_move',
        {'id': id, 'cost': normalized.dx, 'value': normalized.dy});
  }

  void _onMatrixDragStart(String id) {
    _send('matrix_drag_start', {'id': id});
  }

  void _onMatrixDragEnd(String id) {
    _send('matrix_drag_end', {'id': id});
  }

  void _onMatrixRemove(String id) {
    setState(() => _matrixPositions.remove(id));
    _send('matrix_remove', {'id': id});
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
  static const _lastColorPrefsKey = 'last_note_color';
  static const _guestNamePrefsKey = 'guest_display_name';
  static const _problemTextSizePrefsKey = 'problem_statement_text_size';
  String _lastNoteColor = _noteColors.first;
  _ProblemTextSize _problemTextSize = _ProblemTextSize.medium;

  @override
  void initState() {
    super.initState();
    _loadDismissed();
    _loadLastColor();
    _loadProblemTextSize();
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

  Future<void> _loadLastColor() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_lastColorPrefsKey);
    if (saved != null && _noteColors.contains(saved) && mounted) {
      setState(() => _lastNoteColor = saved);
    }
  }

  Future<void> _saveLastColor(String color) async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString(_lastColorPrefsKey, color);
  }

  Future<void> _loadProblemTextSize() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_problemTextSizePrefsKey);
    final size = _ProblemTextSize.fromStorage(saved);
    if (mounted) setState(() => _problemTextSize = size);
  }

  void _setProblemTextSize(_ProblemTextSize size) {
    setState(() => _problemTextSize = size);
    SharedPreferences.getInstance().then((prefs) =>
        prefs.setString(_problemTextSizePrefsKey, size.storageValue));
  }

  Future<void> _loadAndConnect() async {
    final auth = context.read<AuthProvider>();

    if (auth.isAuthenticated) {
      try {
        final api = auth.api;
        final results = await Future.wait([
          api.getBrainstorm(
              groupSlug: widget.groupSlug,
              brainstormSlug: widget.brainstormSlug),
          api.getGroup(widget.groupSlug),
        ]);
        if (!mounted) return;
        final project = results[0] as Brainstorm;
        setState(() {
          _brainstorm = project;
          _group = results[1] as Group;
          if (!project.enableProblem && _slide == 0) _slide = 1;
        });
        _connect(project.id);
      } catch (_) {}
    } else {
      // Unauthenticated — check if guests are enabled for this project.
      try {
        final info = await const ApiService()
            .getGuestBrainstorm(widget.groupSlug, widget.brainstormSlug);
        if (!mounted) return;
        if (info['guests_enabled'] != true) {
          setState(() => _loginRequired = true);
          return;
        }
        final prefs = await SharedPreferences.getInstance();
        final savedName = prefs.getString(_guestNamePrefsKey);
        String name;
        if (savedName != null && savedName.trim().isNotEmpty) {
          name = savedName;
        } else {
          final entered = await _showGuestNameDialog();
          if (entered == null || !mounted) return;
          name = entered;
          await prefs.setString(_guestNamePrefsKey, name);
        }
        final (token, guestUserId) = await const ApiService()
            .guestJoinBrainstorm(info['id'] as String, name);
        if (!mounted) return;
        setState(() {
          _isGuest = true;
          _guestUserId = guestUserId;
          _guestDisplayName = name;
          // Minimal project info for guests, but still carrying every field
          // that affects which slides/UI show (type, retro style, enabled
          // stages, interstitial copy) — otherwise guests fall back to the
          // plain-brainstorm defaults and see the wrong slides/no blur.
          _brainstorm = Brainstorm(
            id: info['id'] as String,
            slug: widget.brainstormSlug,
            name: info['name'] as String,
            description: '',
            groupId: '',
            createdBy: '',
            createdAt: DateTime.now(),
            type: info['type'] as String? ?? 'brainstorm',
            retroStyle: info['retro_style'] as String? ?? '',
            enableProblem: info['enable_problem'] as bool? ?? true,
            enableVote: info['enable_vote'] as bool? ?? true,
            enablePrioritise: info['enable_prioritise'] as bool? ?? true,
            timerEnabled: info['timer_enabled'] as bool? ?? false,
            timerMinutes: info['timer_minutes'] as int? ?? 5,
            interstitialProblem: info['interstitial_problem'] as String? ?? '',
            interstitialBrainstorm:
                info['interstitial_brainstorm'] as String? ?? '',
            interstitialGroup: info['interstitial_group'] as String? ?? '',
            interstitialVote: info['interstitial_vote'] as String? ?? '',
            interstitialPrioritise:
                info['interstitial_prioritise'] as String? ?? '',
            interstitialActionItems:
                info['interstitial_action_items'] as String? ?? '',
          );
          if (_brainstorm?.enableProblem == false && _slide == 0) _slide = 1;
        });
        _connect(info['id'] as String, guestToken: token);
      } catch (_) {
        if (mounted) setState(() => _loginRequired = true);
      }
    }
  }

  Future<String?> _showGuestNameDialog({String? initialName}) {
    final isRename = initialName != null;
    final ctrl = TextEditingController(text: initialName ?? '');
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      barrierDismissible: isRename,
      builder: (ctx) => AlertDialog(
        title: Text(isRename ? 'Change your name' : 'Join as Guest'),
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
            child: Text(isRename ? 'Save' : 'Join'),
          ),
        ],
      ),
    );
  }

  // Lets a joined guest change their display name mid-session. Guest
  // identity is a short-lived JWT with the name baked in (no server-side
  // guest account to patch), so this re-joins with a fresh token/user id —
  // notes/votes already cast under the old guest id keep showing that name,
  // same as a registered user's past notes keep their author at creation time.
  Future<void> _changeGuestName() async {
    if (_brainstorm == null) return;
    final newName = await _showGuestNameDialog(initialName: _guestDisplayName);
    if (newName == null || !mounted || newName == _guestDisplayName) return;
    try {
      final (token, guestUserId) = await const ApiService()
          .guestJoinBrainstorm(_brainstorm!.id, newName);
      if (!mounted) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_guestNamePrefsKey, newName);
      if (!mounted) return;
      _channel?.sink.close();
      setState(() {
        _guestUserId = guestUserId;
        _guestDisplayName = newName;
      });
      _connect(_brainstorm!.id, guestToken: token);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update name')),
        );
      }
    }
  }

  bool get _isPresenter {
    if (_isGuest) return false;
    final userId = context.read<AuthProvider>().user?.id;
    if (userId == null || _brainstorm == null) return false;
    if (_brainstorm!.presenterId != null)
      return userId == _brainstorm!.presenterId;
    return userId == _brainstorm!.createdBy;
  }

  bool get _canAssignPresenter {
    if (_isGuest) return false;
    final userId = context.read<AuthProvider>().user?.id;
    if (userId == null || _brainstorm == null) return false;
    return userId == _brainstorm!.createdBy || userId == _group?.ownerId;
  }

  void _connect(String projectId, {String? guestToken}) {
    final token = guestToken ?? context.read<AuthProvider>().token;
    final uri = Uri.parse(
        '${ApiService.wsBaseUrl}/ws/brainstorms/$projectId?token=$token');
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
          if (_brainstorm?.enableProblem == false && _slide == 0) _slide = 1;
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
            _votes.putIfAbsent(vMap['note_id'] as String,
                () => {})[vMap['user_id'] as String] = vMap['count'] as int;
          }
          _problemStatement = (p['problem_statement'] as String?) ?? '';
          _actionItems = (p['action_items'] as List? ?? [])
              .map((a) => ActionItem.fromJson(a as Map<String, dynamic>))
              .toList();
          if (p['timer'] != null) {
            _applyTimerState(p['timer'] as Map<String, dynamic>);
          }
          _blurNotes = (p['blur_notes'] as bool?) ?? false;
          _connectedCount = (p['connected_count'] as int?) ?? 1;
          _wsInitialized = true;
          if (_notes.isNotEmpty &&
              (_slide == 1 || _slide == 2 || _slide == 3)) {
            _centerIfNeeded();
          }

        case 'note_create':
          _notes.add(StickyNote.fromJson(payload as Map<String, dynamic>));

        case 'note_move':
          final id = payload['id'] as String;
          final idx = _notes.indexWhere((n) => n.id == id);
          if (idx != -1) {
            final column = payload['column'] as String?;
            _notes[idx] = _notes[idx].copyWith(
              posX: (payload['pos_x'] as num).toDouble(),
              posY: (payload['pos_y'] as num).toDouble(),
              column: column,
              clearColumn: column == null,
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

        case 'presence':
          _connectedCount = (payload['count'] as num).toInt();

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

        case 'matrix_remove':
          _matrixPositions.remove(payload['id'] as String);

        case 'slide_change':
          _slide = payload['slide'] as int;

        case 'problem_statement_update':
          _problemStatement = (payload['text'] as String?) ?? '';

        case 'presenter_change':
          if (_brainstorm != null) {
            final pid = payload['presenter_id'] as String?;
            final pname = payload['presenter_username'] as String?;
            _brainstorm = pid == null
                ? _brainstorm!.copyWith(clearPresenter: true)
                : _brainstorm!
                    .copyWith(presenterId: pid, presenterUsername: pname);
          }

        case 'vote':
          final noteId = payload['note_id'] as String;
          final userId = payload['user_id'] as String;
          final count = payload['count'] as int;
          _votes.putIfAbsent(noteId, () => {})[userId] = count;

        case 'votes_cleared':
          // The note stopped being independently votable (it joined a
          // group, or it/its group got deleted) — release those stars
          // back to whoever had placed them.
          _votes.remove(payload['note_id'] as String);

        case 'action_item_create':
          _actionItems
              .add(ActionItem.fromJson(payload as Map<String, dynamic>));

        case 'action_item_update':
          final id = payload['id'] as String;
          final idx = _actionItems.indexWhere((a) => a.id == id);
          if (idx != -1) {
            _actionItems[idx] = _actionItems[idx]
                .copyWith(content: payload['content'] as String);
          }

        case 'action_item_delete':
          _actionItems.removeWhere((a) => a.id == payload['id'] as String);

        case 'timer_update':
          _applyTimerState(payload as Map<String, dynamic>);

        case 'blur_update':
          _blurNotes = payload['enabled'] as bool;
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
        _send('note_move', {
          'id': m.id,
          'pos_x': m.posX,
          'pos_y': m.posY,
          'column': m.column,
        });
      }
    } else {
      // Child or ungrouped note moves independently. Column is resent
      // unchanged so the server's map-update doesn't null it out.
      setState(() {
        _notes[idx] = _notes[idx].copyWith(posX: worldX, posY: worldY);
      });
      _send('note_move', {
        'id': id,
        'pos_x': worldX,
        'pos_y': worldY,
        'column': note.column,
      });
    }
  }

  // Moves a note into a (possibly different) retro column, recomputing its
  // position from the column's x-band and a vertical stack offset.
  void _moveNoteToColumn(String id, String column, double posX, double posY) {
    final idx = _notes.indexWhere((n) => n.id == id);
    if (idx == -1) return;
    setState(() {
      _notes[idx] =
          _notes[idx].copyWith(posX: posX, posY: posY, column: column);
    });
    _send('note_move', {
      'id': id,
      'pos_x': posX,
      'pos_y': posY,
      'column': column,
    });
  }

  void _toggleBlurNotes() {
    _send('blur_toggle', {'enabled': !_blurNotes});
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

  void _createGroupFromNote(String draggedId) {
    _send('note_group_new', {'id': draggedId});
  }

  void _createActionItem(String content) {
    final author = context.read<AuthProvider>().user?.username ?? '';
    _send('action_item_create', {'content': content, 'author': author});
  }

  void _updateActionItem(String id, String content) {
    _send('action_item_update', {'id': id, 'content': content});
  }

  void _deleteActionItem(String id) {
    _send('action_item_delete', {'id': id});
  }

  void _setVote(String noteId, int count) {
    final userId = _myUserId;
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
    if (_group == null || _brainstorm == null) return;
    final members = _group!.members;
    String? selected = _brainstorm!.presenterId;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Set Presenter'),
          content: SizedBox(
            width: 320,
            child: RadioGroup<String?>(
              groupValue: selected,
              onChanged: (v) => setLocal(() => selected = v),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<String?>(
                    title: Text(_brainstorm!.creatorUsername != null
                        ? '${_brainstorm!.creatorUsername} (creator)'
                        : 'Brainstorm creator (default)'),
                    value: null,
                  ),
                  ...members.map((m) => RadioListTile<String?>(
                        title: Text(m.username),
                        subtitle:
                            Text(m.email, style: const TextStyle(fontSize: 11)),
                        value: m.id,
                      )),
                ],
              ),
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
        brainstormSlug: widget.brainstormSlug,
        userId: selected,
      );
      setState(() => _brainstorm = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  void _showProblemStatementReference() {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.lightbulb_outline, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              const Text('Problem Statement'),
            ],
          ),
          content: SizedBox(
            width: 560,
            height: 360,
            child: SingleChildScrollView(
              child: _problemStatement.isEmpty
                  ? Text(
                      'No problem statement defined yet.',
                      style: TextStyle(
                        fontSize: _problemTextSize.fontSize,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  : _ProblemRichText(
                      text: _problemStatement,
                      fontSize: _problemTextSize.fontSize,
                    ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
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
    String selectedColor = _lastNoteColor;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text((_brainstorm?.isCardSort ?? false) ||
                  (_brainstorm?.isRetro ?? false)
              ? 'New Card'
              : 'New Sticky Note'),
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
                          color: selected ? Colors.black87 : Colors.transparent,
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
      setState(() => _lastNoteColor = selectedColor);
      _saveLastColor(selectedColor);
      _send('note_create', {
        'content': contentCtrl.text.trim(),
        'color': selectedColor,
        'pos_x': posX,
        'pos_y': posY,
      });
    }
  }

  // Column x-bands and vertical stacking for the starfish/start-stop-continue
  // retro board, so cards land at a real pos_x/pos_y and the Group slide
  // (which renders notes by absolute position) doesn't stack them all at
  // the same point.
  static const _columnBandWidth = 260.0;
  static const _columnNoteHeight = 110.0;

  double _columnPosX(int columnIndex) => columnIndex * _columnBandWidth;

  double _columnPosY(String column) {
    final countInColumn = _notes.where((n) => n.column == column).length;
    return countInColumn * _columnNoteHeight;
  }

  void _createNoteInColumn(String column, int columnIndex, String content) {
    _send('note_create', {
      'content': content,
      'color': _noteColors.first,
      'pos_x': _columnPosX(columnIndex),
      'pos_y': _columnPosY(column),
      'column': column,
    });
  }

  void _moveNoteToColumnEnd(String id, String column, int columnIndex) {
    _moveNoteToColumn(
        id, column, _columnPosX(columnIndex), _columnPosY(column));
  }

  Future<void> _showAddActionItemDialog() async {
    final contentCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Action Item'),
        content: TextField(
          controller: contentCtrl,
          decoration: const InputDecoration(labelText: 'What needs to happen?'),
          maxLines: 4,
          autofocus: true,
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
    );
    if (confirmed == true && mounted && contentCtrl.text.trim().isNotEmpty) {
      _createActionItem(contentCtrl.text.trim());
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
    _timerTicker?.cancel();
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

    if (_brainstorm == null) {
      // Not loaded yet — for guests this spans the "enter your name" dialog,
      // so don't fall through to the default slide (problem statement),
      // which would flash behind the dialog with the wrong content.
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final isRetro = _brainstorm?.isRetro ?? false;
    final retroStyle = _brainstorm?.retroStyle ?? '';
    final isProblemMode = _slide == 0;
    final isGroupingMode = _slide == 2;
    final enableProblem = _brainstorm?.enableProblem ?? true;
    final enableVote = _brainstorm?.enableVote ?? false;
    final enablePrioritise = _brainstorm?.enablePrioritise ?? false;
    final isVotingMode = _slide == 3 && enableVote;
    final isActionItemsMode = _slide == 4 && isRetro;
    final isCostValueMode = _slide == 4 && !isRetro && enablePrioritise;
    final isRetroBoardMode = _slide == 1 && isRetro;
    final isPresenter = _isPresenter;
    final canAssign = _canAssignPresenter;
    final currentUserId = _myUserId;
    final presenterLabel =
        _brainstorm?.presenterUsername ?? _brainstorm?.creatorUsername ?? '';

    final enabledSlides = [
      if (enableProblem) 0,
      1,
      2,
      if (enableVote) 3,
      if (isRetro || enablePrioritise) 4,
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
            Text(_brainstorm?.name ?? '…'),
            if (presenterLabel.isNotEmpty)
              Text(
                isPresenter
                    ? 'You are presenting'
                    : 'Presenter: $presenterLabel',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: isPresenter
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
        actions: [
          if (enableProblem && !isProblemMode)
            IconButton(
              icon: const Icon(Icons.lightbulb_outline),
              tooltip: 'View problem statement',
              onPressed: _showProblemStatementReference,
            ),
          if (_isGuest)
            IconButton(
              icon: const Icon(Icons.badge_outlined),
              tooltip: 'Change your name ($_guestDisplayName)',
              onPressed: _changeGuestName,
            ),
          if (isPresenter &&
              enabledSlides.isNotEmpty &&
              _slide == enabledSlides.last)
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Export',
              onPressed: () => context.push(
                '/groups/${widget.groupSlug}/brainstorms/${widget.brainstormSlug}/export',
              ),
            ),
          if (canAssign)
            IconButton(
              icon: const Icon(Icons.switch_account_outlined),
              tooltip: 'Set presenter',
              onPressed: _showSetPresenterDialog,
            ),
          if (isPresenter && _slide == 1 && !isRetro)
            IconButton(
              icon: Icon(_blurNotes ? Icons.blur_off : Icons.blur_on),
              tooltip: _blurNotes ? "Show others' notes" : "Blur others' notes",
              onPressed: _toggleBlurNotes,
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
          if (_connected)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: _connectedCount == 1
                    ? '1 person connected'
                    : '$_connectedCount people connected',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.people_outline, size: 18),
                    const SizedBox(width: 4),
                    Text('$_connectedCount'),
                  ],
                ),
              ),
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
      floatingActionButton: _showInterstitial
          ? null
          : isActionItemsMode
              ? FloatingActionButton.extended(
                  onPressed: _showAddActionItemDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Action Item'),
                )
              : _slide == 1 && (!isRetro || retroStyle == 'mad_glad')
                  ? FloatingActionButton.extended(
                      onPressed: _showAddNoteDialog,
                      icon: const Icon(Icons.add),
                      label: Text(_brainstorm?.isCardSort ?? false
                          ? 'Add Card'
                          : 'Add Note'),
                    )
                  : null,
      body: Column(
        children: [
          _SlideTabBar(
            currentSlide: _slide,
            enabled: isPresenter,
            enabledSlides: enabledSlides,
            onSlideChanged: _changeSlide,
            slides: _slidesFor(
              isCardSort: _brainstorm?.isCardSort ?? false,
              isRetro: isRetro,
              retroStyle: retroStyle,
            ),
          ),
          if (isRetroBoardMode && _timerDurationSeconds > 0)
            _RetroTimerBar(
              secondsLeft: _timerSecondsLeft,
              running: _timerRunning,
              isPresenter: isPresenter,
              onStart: _startTimer,
              onPause: _pauseTimer,
              onReset: _resetTimer,
            ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: isProblemMode
                      ? _ProblemStatementSlide(
                          text: _problemStatement,
                          isPresenter: isPresenter,
                          textSize: _problemTextSize,
                          onTextSizeChanged: _setProblemTextSize,
                          onChanged: (text) {
                            setState(() => _problemStatement = text);
                            _psDebounce?.cancel();
                            _psDebounce = Timer(
                              const Duration(milliseconds: 300),
                              () => _send(
                                  'problem_statement_update', {'text': text}),
                            );
                          },
                        )
                      : isActionItemsMode
                          ? _ActionItemsList(
                              items: _actionItems,
                              onCreate: _createActionItem,
                              onUpdate: _updateActionItem,
                              onDelete: _deleteActionItem,
                            )
                          : isCostValueMode
                              ? _CostValueMatrix(
                                  notes: _notes,
                                  positions: _matrixPositions,
                                  lockedBy: _matrixLockedBy,
                                  currentUserId: currentUserId,
                                  votes: _votes,
                                  voteFilterEnabled: enableVote,
                                  onPositionChanged: _onMatrixPositionChanged,
                                  onDragStart: _onMatrixDragStart,
                                  onDragEnd: _onMatrixDragEnd,
                                  onRemoveFromMatrix: _onMatrixRemove,
                                )
                              : isVotingMode
                                  ? _VoteBoard(
                                      notes: _notes,
                                      votes: _votes,
                                      currentUserId: currentUserId,
                                      onSetVote: _setVote,
                                    )
                                  : isRetroBoardMode && retroStyle != 'mad_glad'
                                      ? _RetroColumnBoard(
                                          retroStyle: retroStyle,
                                          notes: _notes,
                                          currentUserId: currentUserId,
                                          onCreateCard: _createNoteInColumn,
                                          onMoveCard: _moveNoteToColumnEnd,
                                          onUpdateCard: _updateNote,
                                        )
                                      : isGroupingMode
                                          ? _GroupingBoard(
                                              notes: _notes,
                                              currentUserId: currentUserId,
                                              isPresenter: isPresenter,
                                              isOwner: canAssign,
                                              onGroupNotes: _groupNotes,
                                              onCreateGroup:
                                                  _createGroupFromNote,
                                              onUngroupNote: _ungroupNote,
                                              onNoteDelete: _deleteNote,
                                              onRenameGroup: _updateNote,
                                            )
                                          : ClipRect(
                                              child: Listener(
                                                onPointerSignal:
                                                    _onPointerSignal,
                                                child: GestureDetector(
                                                  onScaleStart: _onScaleStart,
                                                  onScaleUpdate: _onScaleUpdate,
                                                  child: _InfiniteCanvas(
                                                    notes: _notes
                                                        .where(
                                                            (n) => !n.isGroup)
                                                        .toList(),
                                                    offset: _offset,
                                                    scale: _scale,
                                                    isGroupingMode:
                                                        isGroupingMode,
                                                    groupDragOffsets:
                                                        _groupDragOffsets,
                                                    onNoteMove: _moveNote,
                                                    onNoteDelete: _deleteNote,
                                                    onNoteUpdate: _updateNote,
                                                    onGroupNotes: _groupNotes,
                                                    onUngroupNote: _ungroupNote,
                                                    onFindOverlap: _findOverlap,
                                                    onGroupDragUpdate:
                                                        _onGroupDragUpdate,
                                                    onGroupDragEnd:
                                                        _onGroupDragEnd,
                                                    onNoteDragStart: () =>
                                                        setState(() =>
                                                            _isDraggingNote =
                                                                true),
                                                    onNoteDragEnd: () =>
                                                        setState(() =>
                                                            _isDraggingNote =
                                                                false),
                                                    currentUserId:
                                                        currentUserId,
                                                    isPresenter: isPresenter,
                                                    isOwner: canAssign,
                                                    isCardSort: _brainstorm
                                                            ?.isCardSort ??
                                                        false,
                                                    madGladMode:
                                                        isRetroBoardMode &&
                                                            retroStyle ==
                                                                'mad_glad',
                                                    blurOthersUnlessOwner:
                                                        (isRetroBoardMode &&
                                                                retroStyle ==
                                                                    'mad_glad') ||
                                                            (_slide == 1 &&
                                                                !isRetro &&
                                                                _blurNotes),
                                                  ),
                                                ),
                                              ),
                                            ),
                ),
                if (_showInterstitial)
                  _SlideInterstitial(
                    slide: _slide,
                    isCardSort: _brainstorm?.isCardSort ?? false,
                    isRetro: isRetro,
                    retroStyle: retroStyle,
                    customDescription:
                        _brainstorm?.interstitialForSlide(_slide),
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
// One record per slide carries everything that used to live in three
// parallel lists (tab label, tab icon, interstitial copy) per flow type —
// brainstorm, card sort, and retro each just supply one List<_SlideInfo>.

typedef _SlideInfo = ({
  String label,
  IconData icon,
  String title,
  String description,
  String action,
});

const _standardSlides = <_SlideInfo>[
  (
    label: 'Problem',
    icon: Icons.lightbulb_outline,
    title: 'Problem Statement',
    description:
        'As a team, define the problem you\'re solving. Be specific — a well-framed problem leads to better solutions.',
    action: 'Got it',
  ),
  (
    label: 'Brainstorm',
    icon: Icons.sticky_note_2_outlined,
    title: 'Brainstorm',
    description:
        'Add as many ideas as you like using sticky notes. Quantity over quality — no idea is too small at this stage.',
    action: 'Start brainstorming',
  ),
  (
    label: 'Group',
    icon: Icons.hub_outlined,
    title: 'Group',
    description:
        'Drag similar ideas onto each other to cluster them into themes. Look for patterns across the notes.',
    action: 'Start grouping',
  ),
  (
    label: 'Vote',
    icon: Icons.how_to_vote_outlined,
    title: 'Vote',
    description:
        'You have 4 stars to distribute. Place them on the ideas you think are most valuable to pursue.',
    action: 'Start voting',
  ),
  (
    label: 'Prioritise',
    icon: Icons.grid_view_outlined,
    title: 'Prioritise',
    description:
        'Place each idea on the matrix based on its cost to implement vs the value it delivers to the team.',
    action: 'Start prioritising',
  ),
];

const _cardSortSlides = <_SlideInfo>[
  (
    label: 'Problem',
    icon: Icons.lightbulb_outline,
    title: 'Problem Statement',
    description: '',
    action: 'Got it',
  ),
  (
    label: 'Add Cards',
    icon: Icons.style_outlined,
    title: 'Add Cards',
    description:
        'Add as many cards as you like. Quantity over quality — no card is too small at this stage.',
    action: 'Start adding cards',
  ),
  (
    label: 'Group',
    icon: Icons.hub_outlined,
    title: 'Group',
    description:
        'Drag similar cards onto each other to sort them into categories. Look for patterns across the cards.',
    action: 'Start grouping',
  ),
  (
    label: 'Vote',
    icon: Icons.how_to_vote_outlined,
    title: 'Vote',
    description: '',
    action: 'Start voting',
  ),
  (
    label: 'Prioritise',
    icon: Icons.grid_view_outlined,
    title: 'Prioritise',
    description: '',
    action: 'Start prioritising',
  ),
];

String _retroStyleLabel(String retroStyle) => switch (retroStyle) {
      'starfish' => 'Starfish',
      'start_stop_continue' => 'Start-Stop-Continue',
      'mad_glad' => 'Mad & Glad',
      _ => 'Retro',
    };

List<_SlideInfo> _retroSlides(String retroStyle) => [
      (
        label: 'Problem',
        icon: Icons.lightbulb_outline,
        title: 'Problem Statement',
        description: '',
        action: 'Got it',
      ),
      (
        label: _retroStyleLabel(retroStyle),
        icon: Icons.history_outlined,
        title: _retroStyleLabel(retroStyle),
        description: switch (retroStyle) {
          'starfish' =>
            'Add cards to each column: More of, Less of, Start doing, Stop doing, and Continue.',
          'start_stop_continue' =>
            'Add cards to each column: Start, Stop, and Continue.',
          'mad_glad' =>
            'Add cards anywhere on the board, then drag them left or right to show how mad or glad they make you feel.',
          _ => 'Add as many cards as you like.',
        },
        action: 'Start adding cards',
      ),
      (
        label: 'Group',
        icon: Icons.hub_outlined,
        title: 'Group',
        description:
            'Drag similar cards onto each other to cluster them into themes. Look for patterns across the cards.',
        action: 'Start grouping',
      ),
      (
        label: 'Vote',
        icon: Icons.how_to_vote_outlined,
        title: 'Vote',
        description:
            'You have 4 stars to distribute. Place them on the cards you think matter most.',
        action: 'Start voting',
      ),
      (
        label: 'Action Items',
        icon: Icons.checklist_outlined,
        title: 'Action Items',
        description: 'Add concrete action items the team will follow up on.',
        action: 'Start adding action items',
      ),
    ];

List<_SlideInfo> _slidesFor({
  required bool isCardSort,
  required bool isRetro,
  required String retroStyle,
}) =>
    isRetro
        ? _retroSlides(retroStyle)
        : isCardSort
            ? _cardSortSlides
            : _standardSlides;

class _SlideInterstitial extends StatelessWidget {
  final int slide;
  final VoidCallback onDismiss;
  final String? customDescription;
  final bool isCardSort;
  final bool isRetro;
  final String retroStyle;

  const _SlideInterstitial({
    required this.slide,
    required this.onDismiss,
    this.customDescription,
    this.isCardSort = false,
    this.isRetro = false,
    this.retroStyle = '',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _slidesFor(
        isCardSort: isCardSort, isRetro: isRetro, retroStyle: retroStyle);
    final info = list[slide.clamp(0, list.length - 1)];
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

// ─── Retro step-1 timer ───────────────────────────────────────────────────────

class _RetroTimerBar extends StatelessWidget {
  final int secondsLeft;
  final bool running;
  final bool isPresenter;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onReset;

  const _RetroTimerBar({
    required this.secondsLeft,
    required this.running,
    required this.isPresenter,
    required this.onStart,
    required this.onPause,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final minutes = (secondsLeft ~/ 60).toString().padLeft(2, '0');
    final seconds = (secondsLeft % 60).toString().padLeft(2, '0');
    final expired = secondsLeft == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: expired ? Colors.red.shade100 : Colors.orange.shade200,
      child: Row(
        children: [
          Icon(Icons.timer_outlined,
              size: 18,
              color: expired ? Colors.red.shade900 : Colors.orange.shade900),
          const SizedBox(width: 8),
          Text(
            '$minutes:$seconds',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: expired ? Colors.red.shade900 : Colors.orange.shade900,
            ),
          ),
          const Spacer(),
          if (isPresenter) ...[
            IconButton(
              icon: Icon(running ? Icons.pause : Icons.play_arrow,
                  color:
                      expired ? Colors.red.shade900 : Colors.orange.shade900),
              tooltip: running ? 'Pause timer' : 'Start timer',
              onPressed: running ? onPause : onStart,
            ),
            IconButton(
              icon: Icon(Icons.restart_alt,
                  color:
                      expired ? Colors.red.shade900 : Colors.orange.shade900),
              tooltip: 'Reset timer',
              onPressed: onReset,
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Slide tab bar ────────────────────────────────────────────────────────────

class _SlideTabBar extends StatelessWidget {
  final int currentSlide;
  final bool enabled;
  final List<int> enabledSlides;
  final void Function(int) onSlideChanged;
  final List<_SlideInfo> slides;

  const _SlideTabBar({
    required this.currentSlide,
    required this.enabled,
    required this.enabledSlides,
    required this.onSlideChanged,
    this.slides = _standardSlides,
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
                label: slides[i].label,
                icon: slides[i].icon,
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
            style: TextStyle(
                fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
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
          child:
              Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
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
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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
  final bool isCardSort;
  final bool madGladMode;
  final bool blurOthersUnlessOwner;

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
    this.isCardSort = false,
    this.madGladMode = false,
    this.blurOthersUnlessOwner = false,
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
            if (madGladMode)
              Positioned.fill(
                child: CustomPaint(
                  painter: _MadGladBackgroundPainter(size: size),
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
                        madGladMode
                            ? 'Start adding cards!'
                            : isGroupingMode
                                ? (isCardSort
                                    ? 'No cards to group yet'
                                    : 'No notes to group yet')
                                : (isCardSort
                                    ? 'Start adding cards!'
                                    : 'Start brainstorming!'),
                        style: TextStyle(
                            fontSize: 20, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Text(
                        madGladMode
                            ? 'Tap + Add Card, then drag it left or right'
                            : isGroupingMode
                                ? (isCardSort
                                    ? 'Switch to Add Cards to add cards first'
                                    : 'Switch to Brainstorm to add notes first')
                                : (isCardSort
                                    ? 'Tap + Add Card to place your first card'
                                    : 'Tap + Add Note to place your first idea'),
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
              final maxX = all.map((n) => n.posX + _noteWidth).reduce(max);
              final maxY = all.map((n) => n.posY + _noteMinHeight).reduce(max);
              const pad = 18.0;
              final dragOff = groupDragOffsets[groupNote.id] ?? Offset.zero;
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
            ...[
              ...notes.where((n) => !n.isGroup),
              ...notes.where((n) => n.isGroup)
            ].map((note) {
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
                canDelete:
                    isPresenter || isOwner || note.createdBy == currentUserId,
                blurred:
                    blurOthersUnlessOwner && note.createdBy != currentUserId,
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
      old.offset != offset ||
      old.scale != scale ||
      old.bgColor != bgColor ||
      old.dotColor != dotColor;
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

// ─── Mad/Glad spectrum background ─────────────────────────────────────────────

class _MadGladBackgroundPainter extends CustomPainter {
  final Size size;

  const _MadGladBackgroundPainter({required this.size});

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final rect = Offset.zero & canvasSize;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            const Color(0xFFEF9A9A).withValues(alpha: 0.35),
            const Color(0xFFA5D6A7).withValues(alpha: 0.35),
          ],
        ).createShader(rect),
    );

    for (final (text, alignLeft) in [('MAD', true), ('GLAD', false)]) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
            color: Colors.black.withValues(alpha: 0.28),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = alignLeft ? 24.0 : canvasSize.width - painter.width - 24.0;
      painter.paint(canvas, Offset(dx, 20));
    }
  }

  @override
  bool shouldRepaint(_MadGladBackgroundPainter old) => old.size != size;
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

Widget _maybeBlur(bool blurred, Widget child) => blurred
    ? ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
        child: child,
      )
    : child;

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
  final bool blurred;

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
    this.blurred = false,
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
          onDoubleTap: widget.blurred
              ? null
              : () {
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
            blurred: widget.blurred,
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
  final bool blurred;

  const _NoteCard({
    required this.note,
    required this.isGroupingMode,
    required this.onDelete,
    this.isEditing = false,
    this.showActions = true,
    this.editController,
    this.editFocusNode,
    this.onEditDone,
    this.blurred = false,
  });

  @override
  Widget build(BuildContext context) {
    if (note.isGroup) {
      return _buildGroupCard(context);
    }

    final bg = _hexColor(note.color);
    final isDark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
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
                      : _maybeBlur(
                          blurred,
                          MarkdownBody(
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
                        ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.person_outline, size: 11, color: subtleColor),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          note.author,
                          style: TextStyle(fontSize: 11, color: subtleColor),
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
                          note.content.isEmpty
                              ? 'Untitled group'
                              : note.content,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: note.content.isEmpty
                                ? Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant
                                    .withValues(alpha: 0.5)
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
                    child: Icon(Icons.close,
                        size: 14,
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
  final double fontSize;
  const _ProblemRichText({required this.text, this.fontSize = 36});

  List<InlineSpan> _parse(String text, TextStyle base) {
    final spans = <InlineSpan>[];
    int last = 0;
    for (final match in _ProblemTextController._styleRegex.allMatches(text)) {
      if (match.start > last) {
        spans.add(
            TextSpan(text: text.substring(last, match.start), style: base));
      }
      if (match.group(1) != null) {
        spans.add(TextSpan(
            text: match.group(1),
            style: base.copyWith(fontWeight: FontWeight.bold)));
      } else if (match.group(2) != null) {
        spans.add(TextSpan(
            text: match.group(2),
            style: base.copyWith(decoration: TextDecoration.lineThrough)));
      } else if (match.group(3) != null) {
        spans.add(TextSpan(
            text: match.group(3),
            style: base.copyWith(decoration: TextDecoration.underline)));
      } else if (match.group(4) != null) {
        spans.add(TextSpan(
            text: match.group(4),
            style: base.copyWith(fontStyle: FontStyle.italic)));
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
    final base = TextStyle(
        fontSize: fontSize,
        height: 1.6,
        color: Theme.of(context).colorScheme.onSurface);
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

    final hidden =
        style?.copyWith(fontSize: 0.001, color: Colors.transparent) ??
            const TextStyle(fontSize: 0.001, color: Colors.transparent);

    for (final match in _styleRegex.allMatches(text)) {
      if (match.start > last) {
        spans.add(
            TextSpan(text: text.substring(last, match.start), style: style));
      }

      if (match.group(1) != null) {
        // Bold
        spans.add(TextSpan(text: '**', style: hidden));
        spans.add(TextSpan(
            text: match.group(1),
            style: style?.copyWith(fontWeight: FontWeight.bold)));
        spans.add(TextSpan(text: '**', style: hidden));
      } else if (match.group(2) != null) {
        // Strikethrough
        spans.add(TextSpan(text: '~~', style: hidden));
        spans.add(TextSpan(
            text: match.group(2),
            style: style?.copyWith(decoration: TextDecoration.lineThrough)));
        spans.add(TextSpan(text: '~~', style: hidden));
      } else if (match.group(3) != null) {
        // Underline
        spans.add(TextSpan(text: '__', style: hidden));
        spans.add(TextSpan(
            text: match.group(3),
            style: style?.copyWith(decoration: TextDecoration.underline)));
        spans.add(TextSpan(text: '__', style: hidden));
      } else if (match.group(4) != null) {
        // Italic
        spans.add(TextSpan(text: '*', style: hidden));
        spans.add(TextSpan(
            text: match.group(4),
            style: style?.copyWith(fontStyle: FontStyle.italic)));
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
  final bool showFormatting;
  final _ProblemTextSize textSize;
  final void Function(_ProblemTextSize) onTextSizeChanged;

  const _ProblemToolbar({
    required this.ctrl,
    required this.onChanged,
    required this.showFormatting,
    required this.textSize,
    required this.onTextSizeChanged,
  });

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
    final m = marker.length;

    // Toggle off if the selection is already wrapped in this marker — either
    // because the markers themselves are included in the selection, or
    // because the selection is just the inner text and the markers sit
    // immediately outside it (the common case when selecting rendered,
    // already-bold/underlined/etc text).
    final selWrapped = selected.length >= m * 2 &&
        selected.startsWith(marker) &&
        selected.endsWith(marker);
    final outerWrapped = !selWrapped &&
        sel.start >= m &&
        sel.end + m <= text.length &&
        text.substring(sel.start - m, sel.start) == marker &&
        text.substring(sel.end, sel.end + m) == marker;

    String newText;
    TextSelection newSelection;
    if (selWrapped) {
      final inner = selected.substring(m, selected.length - m);
      newText = text.replaceRange(sel.start, sel.end, inner);
      newSelection = TextSelection(
          baseOffset: sel.start, extentOffset: sel.start + inner.length);
    } else if (outerWrapped) {
      newText = text.replaceRange(sel.start - m, sel.end + m, selected);
      newSelection = TextSelection(
          baseOffset: sel.start - m,
          extentOffset: sel.start - m + selected.length);
    } else {
      final replacement = '$marker$selected$marker';
      newText = text.replaceRange(sel.start, sel.end, replacement);
      final newOffset = sel.isCollapsed ? sel.start + m : sel.end + m * 2;
      newSelection = TextSelection.collapsed(offset: newOffset);
    }

    widget.ctrl.value =
        TextEditingValue(text: newText, selection: newSelection);
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
            if (widget.showFormatting) ...[
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
              const SizedBox(width: 14),
              Container(
                  width: 1,
                  height: 20,
                  color: Theme.of(context).colorScheme.outline),
              const SizedBox(width: 14),
            ],
            PopupMenuButton<_ProblemTextSize>(
              tooltip: 'Text size',
              initialValue: widget.textSize,
              onSelected: widget.onTextSizeChanged,
              itemBuilder: (context) => [
                for (final size in _ProblemTextSize.values)
                  PopupMenuItem(
                    value: size,
                    child: Row(
                      children: [
                        if (size == widget.textSize)
                          Icon(Icons.check,
                              size: 16,
                              color: Theme.of(context).colorScheme.primary)
                        else
                          const SizedBox(width: 16),
                        const SizedBox(width: 8),
                        Text(size.label),
                      ],
                    ),
                  ),
              ],
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(4),
                  border:
                      Border.all(color: Theme.of(context).colorScheme.outline),
                ),
                child: Icon(Icons.format_size,
                    size: 18, color: Theme.of(context).colorScheme.onSurface),
              ),
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
            border: Border.all(color: active ? cs.primary : cs.outline),
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

enum _ProblemTextSize {
  small,
  medium,
  large;

  double get fontSize => switch (this) {
        _ProblemTextSize.small => 22,
        _ProblemTextSize.medium => 36,
        _ProblemTextSize.large => 48,
      };

  String get label => switch (this) {
        _ProblemTextSize.small => 'Small',
        _ProblemTextSize.medium => 'Medium',
        _ProblemTextSize.large => 'Large',
      };

  String get storageValue => name;

  static _ProblemTextSize fromStorage(String? value) => switch (value) {
        'small' => _ProblemTextSize.small,
        'large' => _ProblemTextSize.large,
        _ => _ProblemTextSize.medium,
      };
}

class _ProblemStatementSlide extends StatefulWidget {
  final String text;
  final bool isPresenter;
  final _ProblemTextSize textSize;
  final void Function(_ProblemTextSize) onTextSizeChanged;
  final void Function(String) onChanged;

  const _ProblemStatementSlide({
    required this.text,
    required this.isPresenter,
    required this.textSize,
    required this.onTextSizeChanged,
    required this.onChanged,
  });

  @override
  State<_ProblemStatementSlide> createState() => _ProblemStatementSlideState();
}

class _ProblemStatementSlideState extends State<_ProblemStatementSlide> {
  late final _ProblemTextController _ctrl;
  final UndoHistoryController _undoController = UndoHistoryController();

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
    _undoController.dispose();
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
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                _ProblemToolbar(
                  ctrl: _ctrl,
                  onChanged: widget.onChanged,
                  showFormatting: widget.isPresenter,
                  textSize: widget.textSize,
                  onTextSizeChanged: widget.onTextSizeChanged,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: widget.isPresenter
                      ? TextField(
                          controller: _ctrl,
                          undoController: _undoController,
                          maxLines: null,
                          expands: true,
                          textAlignVertical: TextAlignVertical.top,
                          style: TextStyle(
                              fontSize: widget.textSize.fontSize,
                              height: 1.6,
                              color: cs.onSurface),
                          decoration: InputDecoration(
                            hintText:
                                'Describe the problem you\'re trying to solve…',
                            hintStyle: TextStyle(
                                color:
                                    cs.onSurfaceVariant.withValues(alpha: 0.5),
                                fontSize: widget.textSize.fontSize),
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
                          decoration: BoxDecoration(
                            color: cs.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: cs.outline),
                          ),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: widget.text.isEmpty
                                ? Text(
                                    'No problem statement defined yet.',
                                    style: TextStyle(
                                        fontSize: widget.textSize.fontSize,
                                        color: cs.onSurfaceVariant
                                            .withValues(alpha: 0.5),
                                        fontStyle: FontStyle.italic),
                                  )
                                : _ProblemRichText(
                                    text: widget.text,
                                    fontSize: widget.textSize.fontSize,
                                  ),
                          ),
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

// ─── Grouping board ────────────────────────────────────────────────────────────
// Same drag-and-drop mechanic as the prioritise list: items are rows you drag
// onto another row to group them, instead of nudging sticky notes until they
// happen to overlap on a canvas. Group cards grow to fit however many notes
// are dropped into them.

class _DashedRectPainter extends CustomPainter {
  final Color color;

  const _DashedRectPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect =
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const dashWidth = 6.0;
    const gapWidth = 4.0;
    for (final metric in (Path()..addRRect(rrect)).computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final len = min(dashWidth, metric.length - distance);
        canvas.drawPath(metric.extractPath(distance, distance + len), paint);
        distance += dashWidth + gapWidth;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) => old.color != color;
}

class _GroupingBoard extends StatefulWidget {
  final List<StickyNote> notes;
  final String currentUserId;
  final bool isPresenter;
  final bool isOwner;
  final void Function(String draggedId, String targetId) onGroupNotes;
  final void Function(String draggedId) onCreateGroup;
  final void Function(String id) onUngroupNote;
  final void Function(String id) onNoteDelete;
  final void Function(String id, String content) onRenameGroup;

  const _GroupingBoard({
    required this.notes,
    required this.currentUserId,
    required this.isPresenter,
    required this.isOwner,
    required this.onGroupNotes,
    required this.onCreateGroup,
    required this.onUngroupNote,
    required this.onNoteDelete,
    required this.onRenameGroup,
  });

  @override
  State<_GroupingBoard> createState() => _GroupingBoardState();
}

class _GroupingBoardState extends State<_GroupingBoard> {
  bool _canDelete(StickyNote note) =>
      widget.isPresenter ||
      widget.isOwner ||
      note.createdBy == widget.currentUserId;

  Future<void> _showRenameGroupDialog(StickyNote group) async {
    final controller = TextEditingController(text: group.content);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Group name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim() != group.content) {
      widget.onRenameGroup(group.id, name.trim());
    }
  }

  Future<void> _confirmDeleteGroup(StickyNote group) async {
    final children = widget.notes.where((n) => n.parentId == group.id).toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete group?'),
        content: Text(children.isEmpty
            ? 'This group is empty.'
            : 'The ${children.length} note${children.length == 1 ? '' : 's'} inside will move back to Ungrouped — they will not be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (children.isEmpty) {
      widget.onNoteDelete(group.id);
    } else {
      // Ungrouping the last child makes the server delete the now-empty
      // group note automatically.
      for (final child in children) {
        widget.onUngroupNote(child.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final groups = widget.notes.where((n) => n.isGroup).toList();
    final groupIds = groups.map((g) => g.id).toSet();
    // A note whose parentId points at a group that no longer exists (e.g.
    // the group was deleted directly on Brainstorm before that cascaded
    // properly) is treated as ungrouped rather than vanishing from view.
    final ungrouped = widget.notes
        .where((n) =>
            !n.isGroup &&
            (n.parentId == null || !groupIds.contains(n.parentId)))
        .toList();

    if (groups.isEmpty && ungrouped.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sticky_note_2_outlined,
                size: 72, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No notes to group yet',
                style: TextStyle(fontSize: 20, color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text('Switch to Brainstorm to add notes first',
                style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Whole column is one DragTarget now that rows inside it no
            // longer have their own (card-on-card does nothing) — same
            // pattern as a group column, just accepting = ungroup instead
            // of join.
            DragTarget<String>(
              onAcceptWithDetails: (details) =>
                  widget.onUngroupNote(details.data),
              builder: (context, candidateData, rejectedData) => _buildColumn(
                cs: cs,
                title: 'Ungrouped',
                icon: Icons.sticky_note_2_outlined,
                fill: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                accent: cs.outline,
                count: ungrouped.length,
                dropHighlight: candidateData.isNotEmpty,
                children: ungrouped.map((n) => _buildNoteRow(n, cs)).toList(),
              ),
            ),
            for (final g in groups) ...[
              const SizedBox(width: 16),
              _buildGroupColumn(g, cs),
            ],
            const SizedBox(width: 16),
            _buildNewGroupDropZone(cs),
          ],
        ),
      ),
    );
  }

  // Dropping a card here (open board space — not onto an existing group)
  // starts a brand-new group for it.
  Widget _buildNewGroupDropZone(ColorScheme cs) {
    return DragTarget<String>(
      onAcceptWithDetails: (details) => widget.onCreateGroup(details.data),
      builder: (context, candidateData, rejectedData) => Container(
        width: 200,
        height: 64,
        decoration: BoxDecoration(
          color: candidateData.isNotEmpty
              ? cs.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: CustomPaint(
          painter: _DashedRectPainter(
              color: candidateData.isNotEmpty ? cs.primary : cs.outline),
          child: Center(
            child: Text(
              'Drop here for a\nnew group',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGroupColumn(StickyNote group, ColorScheme cs) {
    final children = widget.notes.where((n) => n.parentId == group.id).toList();
    final (fill, border) = _groupColors(group.id);
    final title = group.content.isEmpty ? 'Untitled group' : group.content;

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != group.id,
      onAcceptWithDetails: (details) =>
          widget.onGroupNotes(details.data, group.id),
      builder: (context, candidateData, rejectedData) => _buildColumn(
        cs: cs,
        title: title,
        icon: Icons.hub_outlined,
        fill: fill,
        accent: border,
        count: children.length,
        dropHighlight: candidateData.isNotEmpty,
        header: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: _columnHeaderContent(
              cs, Icons.hub_outlined, border, title, children.length,
              onTitleTap: () => _showRenameGroupDialog(group),
              onDelete: () => _confirmDeleteGroup(group)),
        ),
        children: children
            .map((n) => _buildNoteRow(n, cs, accent: border, inGroup: true))
            .toList(),
      ),
    );
  }

  Widget _buildNoteRow(
    StickyNote note,
    ColorScheme cs, {
    Color? accent,
    bool inGroup = false,
  }) {
    final bg = _hexColor(note.color);
    final isDark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final content = note.content.isEmpty ? '(empty note)' : note.content;
    final canDelete = _canDelete(note);

    final cardBody = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: accent != null
            ? Border.all(color: accent.withValues(alpha: 0.7))
            : null,
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(0, 1))
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              content,
              style: TextStyle(fontSize: 13, color: textColor),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (inGroup)
            IconButton(
              icon: Icon(Icons.link_off, size: 16, color: textColor),
              tooltip: 'Remove from group',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => widget.onUngroupNote(note.id),
            ),
          if (canDelete)
            IconButton(
              icon: Icon(Icons.delete_outline, size: 16, color: textColor),
              tooltip: 'Delete',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => widget.onNoteDelete(note.id),
            ),
        ],
      ),
    );

    // Plain Draggable — the board is a horizontal Scrollable, and a
    // LongPressDraggable here loses the gesture arena to that scroll as
    // soon as the pointer moves at all, before the long-press timer fires.
    // Accidental merges are now prevented structurally instead (dropping on
    // another card does nothing; only an existing group or the "new group"
    // zone accepts a drop), so the plain Draggable no longer needs it.
    final draggable = _draggableCardRow<String>(
      key: ValueKey(note.id),
      data: note.id,
      child: cardBody,
    );

    // A row is never itself a drop target: dropping one card on another in
    // Ungrouped does nothing, and a row already inside a group is covered
    // by that group's own column-wide DragTarget (nesting another here
    // would fire both accept callbacks on a single drop).
    return Padding(
      padding: EdgeInsets.only(bottom: inGroup ? 6 : 10),
      child: draggable,
    );
  }
}

// Shared by the Group and Vote boards so both read as the same board
// mechanic — a header row plus a vertically-growing list of cards.
Widget _columnHeaderContent(
        ColorScheme cs, IconData icon, Color accent, String title, int count,
        {VoidCallback? onTitleTap, VoidCallback? onDelete}) =>
    Row(
      children: [
        Icon(icon, size: 16, color: accent),
        const SizedBox(width: 8),
        Expanded(
          child: onTitleTap == null
              ? Text(
                  title,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: cs.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : InkWell(
                  onTap: onTitleTap,
                  child: Tooltip(
                    message: 'Tap to rename',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                color: cs.onSurface),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.edit_outlined, size: 12, color: accent),
                      ],
                    ),
                  ),
                ),
        ),
        Text(
          '$count item${count == 1 ? '' : 's'}',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
        if (onDelete != null)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: IconButton(
              icon: Icon(Icons.delete_outline, size: 14, color: accent),
              tooltip: 'Delete group',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: onDelete,
            ),
          ),
      ],
    );

Widget _buildColumn({
  required ColorScheme cs,
  required String title,
  required IconData icon,
  required Color fill,
  required Color accent,
  required int count,
  required List<Widget> children,
  Widget? header,
  bool dropHighlight = false,
}) {
  return Container(
    width: 260,
    decoration: BoxDecoration(
      color: dropHighlight ? accent.withValues(alpha: 0.12) : fill,
      border: Border.all(color: accent, width: dropHighlight ? 2.5 : 1.5),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header ??
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: _columnHeaderContent(cs, icon, accent, title, count),
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Column(
            children: [
              ...children,
              if (dropHighlight)
                Container(
                  margin: EdgeInsets.only(top: children.isEmpty ? 0 : 4),
                  height: 44,
                  width: double.infinity,
                  child:
                      CustomPaint(painter: _DashedRectPainter(color: accent)),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

// Shared by the Group board and Prioritise's sidebar list — a draggable
// card row with the same feedback/childWhenDragging chrome, just with
// room for each caller's own feedback sizing/padding and optional tap.
Widget _draggableCardRow<T extends Object>({
  required Key key,
  required T data,
  required Widget child,
  double feedbackWidth = 260,
  EdgeInsetsGeometry feedbackPadding = EdgeInsets.zero,
  VoidCallback? onTap,
}) {
  return Draggable<T>(
    key: key,
    data: data,
    feedbackOffset: Offset.zero,
    feedback: Material(
      color: Colors.transparent,
      child: Container(
        width: feedbackWidth,
        padding: feedbackPadding,
        child: Opacity(opacity: 0.85, child: child),
      ),
    ),
    childWhenDragging: Opacity(opacity: 0.3, child: child),
    child: onTap == null
        ? child
        : GestureDetector(
            behavior: HitTestBehavior.opaque, onTap: onTap, child: child),
  );
}

// ─── Vote board ────────────────────────────────────────────────────────────────
// Same column mechanic as the Group board (Ungrouped + one column per
// group), plus a "Your votes" pool column. Votes are little star tokens you
// drag onto a card to assign, drag back to the pool to take back, or drag
// straight onto a different card/column to move.

class _VoteToken {
  final String? fromNoteId;
  const _VoteToken({this.fromNoteId});
}

class _VoteBoard extends StatefulWidget {
  final List<StickyNote> notes;
  final Map<String, Map<String, int>> votes;
  final String currentUserId;
  final void Function(String noteId, int count) onSetVote;

  const _VoteBoard({
    required this.notes,
    required this.votes,
    required this.currentUserId,
    required this.onSetVote,
  });

  @override
  State<_VoteBoard> createState() => _VoteBoardState();
}

class _VoteBoardState extends State<_VoteBoard> {
  static const _maxStars = 4;

  int _votesFor(String noteId) =>
      widget.votes[noteId]?[widget.currentUserId] ?? 0;

  int _totalVotesFor(String noteId) {
    final m = widget.votes[noteId];
    if (m == null) return 0;
    return m.values.fold(0, (a, b) => a + b);
  }

  int get _myVotesUsed => widget.votes.values
      .fold(0, (sum, m) => sum + (m[widget.currentUserId] ?? 0));

  int get _starsLeft => _maxStars - _myVotesUsed;

  void _moveVote(String? fromNoteId, String? toNoteId) {
    if (fromNoteId == toNoteId) return;
    if (fromNoteId != null) {
      final cur = _votesFor(fromNoteId);
      if (cur > 0) widget.onSetVote(fromNoteId, cur - 1);
    } else if (_starsLeft <= 0) {
      return; // pool is empty, nothing to place
    }
    if (toNoteId != null) {
      final cur = _votesFor(toNoteId);
      if (cur < _maxStars) widget.onSetVote(toNoteId, cur + 1);
    }
  }

  Widget _buildStarRow(String noteId, Color onColor) {
    final mine = _votesFor(noteId);
    final total = _totalVotesFor(noteId);
    final filled = total > 0;
    final star = Icon(filled ? Icons.star : Icons.star_border,
        size: 18,
        color: filled ? Colors.amber[700] : onColor.withValues(alpha: 0.4));

    // Only draggable when you have a vote here yourself — you can only
    // move or take back your own star, not one someone else placed.
    final starWidget = mine > 0
        ? Draggable<_VoteToken>(
            data: _VoteToken(fromNoteId: noteId),
            feedback: const Icon(Icons.star, size: 24, color: Colors.amber),
            childWhenDragging: Icon(Icons.star_border,
                size: 18, color: onColor.withValues(alpha: 0.4)),
            child: star,
          )
        : star;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        starWidget,
        const SizedBox(width: 4),
        Text('$total',
            style:
                TextStyle(fontSize: 12, color: onColor.withValues(alpha: 0.8))),
      ],
    );
  }

  Widget _buildVotableCard(StickyNote note, ColorScheme cs) {
    final bg = _hexColor(note.color);
    final isDark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final content = note.content.isEmpty ? '(empty note)' : note.content;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DragTarget<_VoteToken>(
        onWillAcceptWithDetails: (d) => d.data.fromNoteId != note.id,
        onAcceptWithDetails: (d) => _moveVote(d.data.fromNoteId, note.id),
        builder: (context, candidateData, rejectedData) => Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: candidateData.isNotEmpty
                ? Border.all(color: cs.primary, width: 2)
                : null,
            boxShadow: const [
              BoxShadow(
                  color: Colors.black12, blurRadius: 2, offset: Offset(0, 1))
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(content,
                  style: TextStyle(fontSize: 13, color: textColor),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              _buildStarRow(note.id, textColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReadOnlyChildRow(StickyNote note, ColorScheme cs, Color accent) {
    final content = note.content.isEmpty ? '(empty note)' : note.content;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Opacity(
        opacity: 0.7,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _hexColor(note.color),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: accent.withValues(alpha: 0.5)),
          ),
          child: Text(content,
              style: TextStyle(
                  fontSize: 12,
                  color: ThemeData.estimateBrightnessForColor(
                              _hexColor(note.color)) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black87),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }

  Widget _buildVotesTray(ColorScheme cs) {
    return DragTarget<_VoteToken>(
      onWillAcceptWithDetails: (d) => d.data.fromNoteId != null,
      onAcceptWithDetails: (d) => _moveVote(d.data.fromNoteId, null),
      builder: (context, candidateData, rejectedData) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: candidateData.isNotEmpty
              ? cs.primary.withValues(alpha: 0.08)
              : cs.surfaceContainerHighest.withValues(alpha: 0.4),
          border: Border(top: BorderSide(color: cs.outline)),
        ),
        child: Row(
          children: [
            Icon(Icons.how_to_vote_outlined, size: 18, color: cs.outline),
            const SizedBox(width: 8),
            Text('Your votes',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: cs.onSurface)),
            const SizedBox(width: 12),
            Expanded(
              child: _starsLeft == 0
                  ? Text('All votes placed',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
                  : Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: List.generate(
                        _starsLeft,
                        (i) => Draggable<_VoteToken>(
                          data: const _VoteToken(),
                          feedback: const Icon(Icons.star,
                              size: 28, color: Colors.amber),
                          childWhenDragging: Icon(Icons.star_border,
                              size: 24, color: cs.outline),
                          child: const Icon(Icons.star,
                              size: 24, color: Colors.amber),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupColumn(StickyNote group, ColorScheme cs) {
    final children = widget.notes.where((n) => n.parentId == group.id).toList();
    final (fill, border) = _groupColors(group.id);
    final title = group.content.isEmpty ? 'Untitled group' : group.content;

    return _buildColumn(
      cs: cs,
      title: title,
      icon: Icons.hub_outlined,
      fill: fill,
      accent: border,
      count: children.length,
      header: DragTarget<_VoteToken>(
        onWillAcceptWithDetails: (d) => d.data.fromNoteId != group.id,
        onAcceptWithDetails: (d) => _moveVote(d.data.fromNoteId, group.id),
        builder: (context, candidateData, rejectedData) => Container(
          decoration: BoxDecoration(
            color: candidateData.isNotEmpty
                ? border.withValues(alpha: 0.25)
                : Colors.transparent,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Icon(Icons.hub_outlined, size: 16, color: border),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: cs.onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              _buildStarRow(group.id, cs.onSurface),
            ],
          ),
        ),
      ),
      children:
          children.map((n) => _buildReadOnlyChildRow(n, cs, border)).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final groups = widget.notes.where((n) => n.isGroup).toList();
    final groupIds = groups.map((g) => g.id).toSet();
    final ungrouped = widget.notes
        .where((n) =>
            !n.isGroup &&
            (n.parentId == null || !groupIds.contains(n.parentId)))
        .toList();

    final isEmpty = groups.isEmpty && ungrouped.isEmpty;

    return Column(
      children: [
        Expanded(
          child: isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.how_to_vote_outlined,
                          size: 72, color: cs.onSurfaceVariant),
                      const SizedBox(height: 16),
                      Text('No notes to vote on yet',
                          style: TextStyle(
                              fontSize: 20, color: cs.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      Text('Add notes in Brainstorm and group them first',
                          style: TextStyle(color: cs.onSurfaceVariant)),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildColumn(
                          cs: cs,
                          title: 'Ungrouped',
                          icon: Icons.sticky_note_2_outlined,
                          fill:
                              cs.surfaceContainerHighest.withValues(alpha: 0.4),
                          accent: cs.outline,
                          count: ungrouped.length,
                          children: ungrouped
                              .map((n) => _buildVotableCard(n, cs))
                              .toList(),
                        ),
                        for (final g in groups) ...[
                          const SizedBox(width: 16),
                          _buildGroupColumn(g, cs),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
        _buildVotesTray(cs),
      ],
    );
  }
}

// ─── Cost-value matrix ─────────────────────────────────────────────────────────

class _CostValueMatrix extends StatefulWidget {
  final List<StickyNote> notes;
  final Map<String, Offset> positions;
  final Map<String, String> lockedBy;
  final String currentUserId;
  final Map<String, Map<String, int>> votes;
  final bool voteFilterEnabled;
  final void Function(String id, Offset normalized) onPositionChanged;
  final void Function(String id) onDragStart;
  final void Function(String id) onDragEnd;
  final void Function(String id) onRemoveFromMatrix;

  const _CostValueMatrix({
    required this.notes,
    required this.positions,
    required this.lockedBy,
    required this.currentUserId,
    required this.votes,
    required this.voteFilterEnabled,
    required this.onPositionChanged,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onRemoveFromMatrix,
  });

  @override
  State<_CostValueMatrix> createState() => _CostValueMatrixState();
}

class _CostValueMatrixState extends State<_CostValueMatrix> {
  final _stackKey = GlobalKey();
  double _matrixLeft = 0, _matrixTop = 0, _matrixW = 1, _matrixH = 1;
  String? _expandedId;

  // Matches the Positioned(left: pos.dx - r, top: pos.dy - r - 10) used to
  // render each dot below: `pos` (what toScreen/_globalToNormalized deal in)
  // is defined as the dot's top-left plus this offset. DragTarget always
  // reports the dropped feedback widget's top-left (regardless of drag
  // anchor strategy), so this same offset converts that back to `pos`.
  static const _dotRadius = 18.0;
  static const _dotTopLeftToPos = Offset(_dotRadius, _dotRadius + 10);

  Offset _posFor(String id) => widget.positions[id] ?? const Offset(0.5, 0.5);

  Color _dotColor(StickyNote note) =>
      note.isGroup ? _groupColors(note.id).$2 : _hexColor(note.color);

  Widget _sectionHeader(String label, ColorScheme cs) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant,
              letterSpacing: 0.8),
        ),
      );

  Widget _buildItemRow(
    StickyNote note, {
    required bool isMobile,
    required ColorScheme cs,
    bool onBoard = false,
  }) {
    final color = _dotColor(note);
    final children = note.isGroup
        ? widget.notes.where((n) => n.parentId == note.id).toList()
        : const <StickyNote>[];
    final childCount = children.length;
    final label = note.content.isEmpty
        ? (note.isGroup ? 'Untitled group' : '')
        : note.content;
    final isExpanded = _expandedId == note.id;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: note.isGroup ? _groupColors(note.id).$1 : color,
              border: Border.all(color: color, width: 2),
            ),
            child: note.isGroup
                ? Center(
                    child: Icon(Icons.hub_outlined, size: 10, color: color))
                : null,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: cs.onSurface),
                  maxLines: isExpanded ? null : 1,
                  overflow:
                      isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                ),
                if (note.isGroup && childCount > 0)
                  Text(
                    '$childCount item${childCount == 1 ? '' : 's'}',
                    style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                  ),
                if (isExpanded && note.isGroup && children.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: children
                          .map((child) => Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Text(
                                  '•  ${child.content.isEmpty ? '(empty note)' : child.content}',
                                  style: TextStyle(
                                      fontSize: 11, color: cs.onSurfaceVariant),
                                ),
                              ))
                          .toList(),
                    ),
                  ),
              ],
            ),
          ),
          if (onBoard) Icon(Icons.push_pin, size: 13, color: cs.primary),
        ],
      ),
    );
    return _draggableCardRow<String>(
      key: ValueKey(note.id),
      data: note.id,
      feedbackWidth: isMobile ? 140 : 220,
      feedbackPadding: const EdgeInsets.symmetric(horizontal: 8),
      onTap: () => setState(() => _expandedId = isExpanded ? null : note.id),
      child: row,
    );
  }

  int _totalVotesFor(String id) {
    final m = widget.votes[id];
    if (m == null) return 0;
    return m.values.fold(0, (a, b) => a + b);
  }

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
    final groupIds =
        widget.notes.where((n) => n.isGroup).map((n) => n.id).toSet();
    // Same orphan guard as the grouping board: a note whose parentId points
    // at a since-deleted group counts as top-level, not hidden.
    var items = widget.notes
        .where((n) =>
            n.isGroup || n.parentId == null || !groupIds.contains(n.parentId))
        .toList();
    if (widget.voteFilterEnabled) {
      items = items.where((n) => _totalVotesFor(n.id) > 0).toList();
    }

    if (items.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_view_outlined,
                size: 72, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
                widget.voteFilterEnabled
                    ? 'No items have votes yet'
                    : 'No notes yet',
                style: TextStyle(fontSize: 20, color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text(
                widget.voteFilterEnabled
                    ? 'Vote on notes in the Voting slide first'
                    : 'Add notes in the Brainstorm slide first',
                style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }

    final unplaced =
        items.where((n) => !widget.positions.containsKey(n.id)).toList();
    final placed =
        items.where((n) => widget.positions.containsKey(n.id)).toList();

    final isMobile = MediaQuery.of(context).size.width < 600;

    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Left list ──────────────────────────────────────────────────────
        DragTarget<String>(
          onAcceptWithDetails: (details) =>
              widget.onRemoveFromMatrix(details.data),
          builder: (context, candidateData, rejectedData) => Container(
            width: isMobile ? 140 : 220,
            decoration: BoxDecoration(
              color: candidateData.isNotEmpty
                  ? cs.primary.withValues(alpha: 0.08)
                  : cs.surface,
              border: Border(right: BorderSide(color: cs.outline)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                    children: [
                      if (placed.isNotEmpty) _sectionHeader('ON BOARD', cs),
                      ...placed.map((note) => _buildItemRow(note,
                          isMobile: isMobile, cs: cs, onBoard: true)),
                      _sectionHeader('ITEMS', cs),
                      ...unplaced.map((note) =>
                          _buildItemRow(note, isMobile: isMobile, cs: cs)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // ── Matrix area ────────────────────────────────────────────────────
        Expanded(
          child: DragTarget<String>(
            onAcceptWithDetails: (details) {
              // details.offset is always the dropped feedback widget's
              // top-left corner. Invert the same (pos -> top-left) formula
              // used to render the dot so the stored position reproduces
              // exactly where it was released.
              final normalized =
                  _globalToNormalized(details.offset + _dotTopLeftToPos);
              widget.onPositionChanged(details.data, normalized);
            },
            builder: (context, candidateData, rejectedData) =>
                LayoutBuilder(builder: (context, constraints) {
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

              final isDarkMode =
                  Theme.of(context).brightness == Brightness.dark;
              return Stack(key: _stackKey, children: [
                // Background fill
                Positioned.fill(
                    child: Container(
                        color: Theme.of(context).scaffoldBackgroundColor)),
                // Quadrant grid
                Positioned(
                  left: matrixLeft,
                  top: matrixTop,
                  width: matrixW,
                  height: matrixH,
                  child:
                      CustomPaint(painter: _MatrixPainter(isDark: isDarkMode)),
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
                  child: _quadrantChip(
                      'Strategic', Icons.trending_up, const Color(0xFF1565C0)),
                ),
                Positioned(
                  left: matrixLeft + 10,
                  top: matrixTop + matrixH / 2 + 10,
                  child: _quadrantChip(
                      'Fill-ins', Icons.low_priority, const Color(0xFF6D4C41)),
                ),
                Positioned(
                  left: matrixLeft + matrixW / 2 + 10,
                  top: matrixTop + matrixH / 2 + 10,
                  child: _quadrantChip('Time Sinks',
                      Icons.do_not_disturb_outlined, const Color(0xFFC62828)),
                ),
                // Circles
                ...placed.map((note) {
                  final pos = toScreen(_posFor(note.id));
                  final color = _dotColor(note);
                  const r = _dotRadius;
                  final isDark = ThemeData.estimateBrightnessForColor(color) ==
                      Brightness.dark;
                  final iconColor = isDark ? Colors.white70 : Colors.white;
                  final lockedByOther = widget.lockedBy.containsKey(note.id) &&
                      widget.lockedBy[note.id] != widget.currentUserId;

                  final dotContent = Column(
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
                  );

                  return Positioned(
                    left: pos.dx - r,
                    top: pos.dy - r - 10,
                    child: Opacity(
                      opacity: lockedByOther ? 0.35 : 1.0,
                      child: Draggable<String>(
                        data: note.id,
                        maxSimultaneousDrags: lockedByOther ? 0 : 1,
                        onDragStarted: () => widget.onDragStart(note.id),
                        onDragEnd: (_) => widget.onDragEnd(note.id),
                        feedback: Opacity(opacity: 0.85, child: dotContent),
                        childWhenDragging:
                            Opacity(opacity: 0.3, child: dotContent),
                        child: dotContent,
                      ),
                    ),
                  );
                }),
              ]);
            }),
          ),
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
    canvas.drawRect(
        Rect.fromLTWH(0, 0, half.width, half.height), Paint()..color = q1);
    canvas.drawRect(Rect.fromLTWH(half.width, 0, half.width, half.height),
        Paint()..color = q2);
    canvas.drawRect(Rect.fromLTWH(0, half.height, half.width, half.height),
        Paint()..color = q3);
    canvas.drawRect(
        Rect.fromLTWH(half.width, half.height, half.width, half.height),
        Paint()..color = q4);

    final borderColor =
        isDark ? const Color(0xFF3A3A55) : const Color(0xFFBBBBBB);
    final border = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), border);

    final dividerColor =
        isDark ? const Color(0xFF555566) : const Color(0xFF999999);
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

// ─── Retro column board (starfish / start-stop-continue) ──────────────────────

List<(String, String)> _retroColumnsFor(String retroStyle) =>
    switch (retroStyle) {
      'starfish' => const [
          ('more_of', 'More of'),
          ('less_of', 'Less of'),
          ('start', 'Start doing'),
          ('stop', 'Stop doing'),
          ('continue', 'Continue'),
        ],
      'start_stop_continue' => const [
          ('start', 'Start'),
          ('stop', 'Stop'),
          ('continue', 'Continue'),
        ],
      _ => const [],
    };

class _RetroColumnBoard extends StatelessWidget {
  final String retroStyle;
  final List<StickyNote> notes;
  final String currentUserId;
  final void Function(String column, int columnIndex, String content)
      onCreateCard;
  final void Function(String noteId, String column, int columnIndex) onMoveCard;
  final void Function(String id, String content) onUpdateCard;

  const _RetroColumnBoard({
    required this.retroStyle,
    required this.notes,
    required this.currentUserId,
    required this.onCreateCard,
    required this.onMoveCard,
    required this.onUpdateCard,
  });

  Future<void> _promptAddCard(
      BuildContext context, String column, int columnIndex) async {
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Card'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'What\'s on your mind?'),
          maxLines: 4,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) Navigator.pop(ctx, true);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (confirmed == true && ctrl.text.trim().isNotEmpty) {
      onCreateCard(column, columnIndex, ctrl.text.trim());
    }
  }

  Future<void> _promptEditCard(BuildContext context, StickyNote note) async {
    final ctrl = TextEditingController(text: note.content);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Card'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed == true && ctrl.text.trim().isNotEmpty) {
      onUpdateCard(note.id, ctrl.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final columns = _retroColumnsFor(retroStyle);
    return Container(
      color: cs.surfaceContainerHighest,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: columns.indexed.map((entry) {
            final (index, column) = entry;
            final key = column.$1;
            final label = column.$2;
            final cards = notes.where((n) => n.column == key).toList()
              ..sort((a, b) => a.posY.compareTo(b.posY));
            return Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _RetroColumn(
                label: label,
                cards: cards,
                currentUserId: currentUserId,
                onAdd: () => _promptAddCard(context, key, index),
                onDropNote: (noteId) => onMoveCard(noteId, key, index),
                onEditCard: (note) => _promptEditCard(context, note),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _RetroColumn extends StatelessWidget {
  final String label;
  final List<StickyNote> cards;
  final String currentUserId;
  final VoidCallback onAdd;
  final void Function(String noteId) onDropNote;
  final void Function(StickyNote note) onEditCard;

  const _RetroColumn({
    required this.label,
    required this.cards,
    required this.currentUserId,
    required this.onAdd,
    required this.onDropNote,
    required this.onEditCard,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 240,
      height: double.infinity,
      child: DragTarget<String>(
        onAcceptWithDetails: (details) => onDropNote(details.data),
        builder: (context, candidateData, rejectedData) {
          final highlighted = candidateData.isNotEmpty;
          return Container(
            decoration: BoxDecoration(
              color: highlighted
                  ? cs.primaryContainer.withValues(alpha: 0.3)
                  : cs.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(label,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add, size: 18),
                        onPressed: onAdd,
                        tooltip: 'Add card',
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(8),
                    children: cards.map((note) {
                      final isOwn = note.createdBy == currentUserId;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Draggable<String>(
                          data: note.id,
                          feedback: Material(
                            color: Colors.transparent,
                            child: SizedBox(
                                width: 212,
                                child: _RetroCard(note: note, isOwn: isOwn)),
                          ),
                          childWhenDragging: Opacity(
                              opacity: 0.3,
                              child: _RetroCard(note: note, isOwn: isOwn)),
                          child: _RetroCard(
                            note: note,
                            isOwn: isOwn,
                            onTap: isOwn ? () => onEditCard(note) : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RetroCard extends StatelessWidget {
  final StickyNote note;
  final bool isOwn;
  final VoidCallback? onTap;

  const _RetroCard({required this.note, required this.isOwn, this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = _hexColor(note.color);
    final isDark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final text = Text(
      note.content,
      style: TextStyle(
        fontSize: 13,
        color: textColor,
        fontWeight: FontWeight.w500,
      ),
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
        ),
        child: isOwn
            ? text
            : ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                child: text,
              ),
      ),
    );
  }
}

// ─── Action items list ─────────────────────────────────────────────────────────

class _ActionItemsList extends StatelessWidget {
  final List<ActionItem> items;
  final void Function(String content) onCreate;
  final void Function(String id, String content) onUpdate;
  final void Function(String id) onDelete;

  const _ActionItemsList({
    required this.items,
    required this.onCreate,
    required this.onUpdate,
    required this.onDelete,
  });

  Future<void> _edit(BuildContext context, ActionItem item) async {
    final ctrl = TextEditingController(text: item.content);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Action Item'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed == true && ctrl.text.trim().isNotEmpty) {
      onUpdate(item.id, ctrl.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checklist_outlined,
                size: 72, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No action items yet',
                style: TextStyle(fontSize: 20, color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text('Tap + Add Action Item to add the first one',
                style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            leading: const Icon(Icons.task_alt_outlined),
            title: Text(item.content),
            subtitle: item.author.isNotEmpty ? Text(item.author) : null,
            onTap: () => _edit(context, item),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => onDelete(item.id),
            ),
          ),
        );
      },
    );
  }
}
