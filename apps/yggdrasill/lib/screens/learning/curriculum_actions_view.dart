import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../app_overlays.dart';
import '../../models/behavior_card_drag_payload.dart';
import '../../services/learning_behavior_card_service.dart';
import '../../widgets/animated_reorderable_grid.dart';
import '../../widgets/dialog_tokens.dart';

const List<IconData> _behaviorIconPack = [
  Icons.directions_run,
  Icons.self_improvement,
  Icons.psychology_alt,
  Icons.task_alt,
  Icons.timer_outlined,
  Icons.fitness_center,
  Icons.menu_book_rounded,
  Icons.edit_note_rounded,
  Icons.school_rounded,
  Icons.lightbulb_outline_rounded,
];

const List<Color> _behaviorColorPack = [
  Color(0xFF1E2A36),
  Color(0xFF20313B),
  Color(0xFF222C44),
  Color(0xFF2B2A3B),
  Color(0xFF2C2437),
  Color(0xFF1E3234),
  Color(0xFF24312A),
  Color(0xFF2E2A24),
  Color(0xFF2A2E3C),
  Color(0xFF2F2B35),
];

class CurriculumActionsView extends StatefulWidget {
  const CurriculumActionsView({super.key});

  @override
  State<CurriculumActionsView> createState() => _CurriculumActionsViewState();
}

class _CurriculumActionsViewState extends State<CurriculumActionsView> {
  final List<_BehaviorCard> _cards = [];
  final ScrollController _gridScrollCtrl = ScrollController();
  final Uuid _uuid = const Uuid();

  bool _loading = true;
  bool _saving = false;
  bool _saveQueued = false;
  bool _saveInFlight = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFromServer());
  }

  @override
  void dispose() {
    _clearBehaviorCardDragPayload();
    _gridScrollCtrl.dispose();
    super.dispose();
  }

  List<_BehaviorCard> _orderedCards() {
    final list = List<_BehaviorCard>.from(_cards);
    list.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return list;
  }

  Color _colorForIndex(int index) =>
      _behaviorColorPack[index % _behaviorColorPack.length];

  LearningBehaviorCardRecord _toRecord(_BehaviorCard card) {
    return LearningBehaviorCardRecord(
      id: card.id,
      name: card.name,
      repeatDays: card.repeatDays,
      isIrregular: card.isIrregular,
      levelContents: card.levelContents,
      selectedLevelIndex: card.selectedLevelIndex,
      icon: card.icon,
      color: card.color,
      orderIndex: card.orderIndex,
    );
  }

  _BehaviorCard _fromRecord(LearningBehaviorCardRecord card) {
    return _BehaviorCard(
      id: card.id,
      name: card.name,
      repeatDays: card.repeatDays,
      isIrregular: card.isIrregular,
      levelContents:
          card.levelContents.isEmpty ? const <String>[''] : card.levelContents,
      selectedLevelIndex: card.selectedLevelIndex
          .clamp(
            0,
            (card.levelContents.isEmpty ? 1 : card.levelContents.length) - 1,
          )
          .toInt(),
      icon: card.icon,
      color: card.color,
      orderIndex: card.orderIndex,
    );
  }

  Future<void> _loadFromServer() async {
    setState(() => _loading = true);
    try {
      final rows = await LearningBehaviorCardService.instance.loadCards();
      if (!mounted) return;
      setState(() {
        _cards
          ..clear()
          ..addAll(rows.map(_fromRecord));
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('행동 카드 로드에 실패했습니다.')),
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _requestSave() {
    _saveQueued = true;
    if (_saveInFlight) return;
    unawaited(_flushSaveQueue());
  }

  Future<void> _flushSaveQueue() async {
    if (_saveInFlight) return;
    _saveInFlight = true;
    if (mounted) setState(() => _saving = true);

    try {
      while (_saveQueued) {
        _saveQueued = false;
        final snapshot = _orderedCards();
        if (snapshot.isEmpty) continue;
        final rows = snapshot.map(_toRecord).toList();
        await LearningBehaviorCardService.instance.saveAll(rows);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('행동 카드 서버 저장에 실패했습니다.')),
        );
      }
    } finally {
      _saveInFlight = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  void _setBehaviorCardDragPayload(_BehaviorCard card) {
    final int levelIndex = card.selectedLevelIndex
        .clamp(0, card.levelContents.isEmpty ? 0 : card.levelContents.length - 1)
        .toInt();
    final String levelText = card.levelContents.isEmpty
        ? ''
        : card.levelContents[levelIndex];
    activeBehaviorCardDragPayload.value = BehaviorCardDragPayload(
      cardId: card.id,
      name: card.name,
      repeatDays: card.repeatDays,
      isIrregular: card.isIrregular,
      levelContents: List<String>.from(card.levelContents),
      dragStartLevelIndex: levelIndex,
      dragStartLevelText: levelText,
    );
    isBehaviorDraggingOverLeftSideSheet.value = false;
  }

  void _clearBehaviorCardDragPayload() {
    activeBehaviorCardDragPayload.value = null;
    isBehaviorDraggingOverLeftSideSheet.value = false;
  }

  Widget _buildCompactBehaviorDragFeedback(
    _BehaviorCard card, {
    required double maxWidth,
  }) {
    double width = maxWidth * 0.7;
    if (width > 188) width = 188;
    if (width < 152) width = 152;
    return Container(
      width: width,
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF141E22),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.28),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: card.color.withOpacity(0.38),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(card.icon, color: Colors.white70, size: 16),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  card.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '레벨 ${card.selectedLevelIndex + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBehaviorDragFeedbackCell(
    _BehaviorCard card, {
    required double maxWidth,
  }) {
    final normal = _BehaviorCardTile(
      card: card,
      onTap: () {},
      onLevelDelta: (_) {},
    );
    return ValueListenableBuilder<bool>(
      valueListenable: isBehaviorDraggingOverLeftSideSheet,
      builder: (context, hoveringSideSheet, _) {
        final payload = activeBehaviorCardDragPayload.value;
        final bool compact = hoveringSideSheet &&
            payload != null &&
            payload.cardId == card.id;
        if (!compact) return normal;
        return Align(
          alignment: Alignment.topLeft,
          child: _buildCompactBehaviorDragFeedback(
            card,
            maxWidth: maxWidth,
          ),
        );
      },
    );
  }

  void _commitCardReorder({
    required String id,
    required int targetIndex,
  }) {
    final ordered = _orderedCards();
    if (ordered.isEmpty) return;
    final fromIdx = ordered.indexWhere((x) => x.id == id);
    if (fromIdx == -1) return;

    final moved = ordered.removeAt(fromIdx);
    final toIdx = targetIndex.clamp(0, ordered.length).toInt();
    ordered.insert(toIdx, moved);

    for (int i = 0; i < ordered.length; i++) {
      final gIdx = _cards.indexWhere((x) => x.id == ordered[i].id);
      if (gIdx != -1 && _cards[gIdx].orderIndex != i) {
        _cards[gIdx] = _cards[gIdx].copyWith(orderIndex: i);
      }
    }
  }

  void _changeLevel({
    required String id,
    required int delta,
  }) {
    final idx = _cards.indexWhere((x) => x.id == id);
    if (idx == -1) return;
    final card = _cards[idx];
    if (card.levelContents.isEmpty) return;
    final next = (card.selectedLevelIndex + delta)
        .clamp(0, card.levelContents.length - 1)
        .toInt();
    if (next == card.selectedLevelIndex) return;
    setState(() {
      _cards[idx] = card.copyWith(selectedLevelIndex: next);
    });
    _requestSave();
  }

  Future<void> _openCreateDialog() async {
    final draft = await showDialog<_BehaviorCardDraft>(
      context: context,
      builder: (context) => const _BehaviorCardEditorDialog(),
    );
    if (!mounted || draft == null) return;
    setState(() {
      final insertIndex = _cards.length;
      _cards.add(
        _BehaviorCard(
          id: _uuid.v4(),
          name: draft.name,
          repeatDays: draft.repeatDays,
          isIrregular: draft.isIrregular,
          levelContents: draft.levelContents,
          selectedLevelIndex: 0,
          icon: draft.icon,
          color: _colorForIndex(insertIndex),
          orderIndex: insertIndex,
        ),
      );
    });
    _requestSave();
  }

  Future<void> _openEditDialog(_BehaviorCard card) async {
    final draft = await showDialog<_BehaviorCardDraft>(
      context: context,
      builder: (context) => _BehaviorCardEditorDialog(initialCard: card),
    );
    if (!mounted || draft == null) return;
    setState(() {
      final idx = _cards.indexWhere((x) => x.id == card.id);
      if (idx == -1) return;
      final current = _cards[idx];
      final nextSelected = current.selectedLevelIndex
          .clamp(0, draft.levelContents.length - 1)
          .toInt();
      _cards[idx] = current.copyWith(
        name: draft.name,
        repeatDays: draft.repeatDays,
        isIrregular: draft.isIrregular,
        levelContents: draft.levelContents,
        selectedLevelIndex: nextSelected,
        icon: draft.icon,
      );
    });
    _requestSave();
  }

  @override
  Widget build(BuildContext context) {
    final orderedCards = _orderedCards();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const double gridCardWidth = 290.0;
          const double gridCardHeight = 182.0;
          const double spacing = 16.0;
          final int cols = (constraints.maxWidth / (gridCardWidth + spacing))
              .floor()
              .clamp(1, 999)
              .toInt();
          final double gridWidth =
              (cols * gridCardWidth) + ((cols - 1) * spacing);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 2, 2, 14),
                child: Row(
                  children: [
                    const Text(
                      '행동',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C2528),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: const Text(
                        '레벨별 행동 카드',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (_saving)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: Text(
                          '저장 중...',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    Tooltip(
                      message: '행동 카드 추가',
                      child: IconButton(
                        onPressed: _loading ? null : _openCreateDialog,
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF1D2C31),
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white12),
                        ),
                        icon: const Icon(Icons.add_rounded, size: 22),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(color: kDlgTextSub),
                        )
                      : orderedCards.isEmpty
                      ? _EmptyActionCardPanel(onCreate: _openCreateDialog)
                      : SizedBox(
                          width: gridWidth,
                          child: AnimatedReorderableGrid<_BehaviorCard>(
                            items: orderedCards,
                            itemId: (card) => card.id,
                            itemBuilder: (context, card) => _BehaviorCardTile(
                              card: card,
                              onTap: () => _openEditDialog(card),
                              onLevelDelta: (delta) {
                                _changeLevel(id: card.id, delta: delta);
                              },
                            ),
                            feedbackBuilder: (context, card) =>
                                _buildBehaviorDragFeedbackCell(
                              card,
                              maxWidth: gridCardWidth,
                            ),
                            cardWidth: gridCardWidth,
                            cardHeight: gridCardHeight,
                            spacing: spacing,
                            columns: cols,
                            dragAnchorStrategy: pointerDragAnchorStrategy,
                            scrollController: _gridScrollCtrl,
                            animationDuration:
                                const Duration(milliseconds: 180),
                            animationCurve: Curves.easeOutCubic,
                            onDragStarted: _setBehaviorCardDragPayload,
                            onDragEnded: (_) => _clearBehaviorCardDragPayload(),
                            onReorder: (card, targetIndex) {
                              setState(() {
                                _commitCardReorder(
                                  id: card.id,
                                  targetIndex: targetIndex,
                                );
                              });
                              _requestSave();
                            },
                          ),
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BehaviorCard {
  final String id;
  final String name;
  final int repeatDays;
  final bool isIrregular;
  final List<String> levelContents;
  final int selectedLevelIndex;
  final IconData icon;
  final Color color;
  final int orderIndex;

  const _BehaviorCard({
    required this.id,
    required this.name,
    required this.repeatDays,
    required this.isIrregular,
    required this.levelContents,
    required this.selectedLevelIndex,
    required this.icon,
    required this.color,
    required this.orderIndex,
  });

  String get selectedLevelText => levelContents[selectedLevelIndex];

  _BehaviorCard copyWith({
    String? name,
    int? repeatDays,
    bool? isIrregular,
    List<String>? levelContents,
    int? selectedLevelIndex,
    int? orderIndex,
    IconData? icon,
    Color? color,
  }) {
    return _BehaviorCard(
      id: id,
      name: name ?? this.name,
      repeatDays: repeatDays ?? this.repeatDays,
      isIrregular: isIrregular ?? this.isIrregular,
      levelContents: levelContents ?? this.levelContents,
      selectedLevelIndex: selectedLevelIndex ?? this.selectedLevelIndex,
      icon: icon ?? this.icon,
      color: color ?? this.color,
      orderIndex: orderIndex ?? this.orderIndex,
    );
  }
}

class _BehaviorCardTile extends StatefulWidget {
  final _BehaviorCard card;
  final VoidCallback onTap;
  final ValueChanged<int> onLevelDelta;

  const _BehaviorCardTile({
    required this.card,
    required this.onTap,
    required this.onLevelDelta,
  });

  @override
  State<_BehaviorCardTile> createState() => _BehaviorCardTileState();
}

class _BehaviorCardTileState extends State<_BehaviorCardTile> {
  double _levelDragDx = 0.0;

  void _handleLevelDragUpdate(DragUpdateDetails details) {
    _levelDragDx += details.delta.dx;
    if (_levelDragDx <= -48) {
      _levelDragDx = 0.0;
      widget.onLevelDelta(-1);
    } else if (_levelDragDx >= 48) {
      _levelDragDx = 0.0;
      widget.onLevelDelta(1);
    }
  }

  void _handlePointerSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    final dx = signal.scrollDelta.dx;
    final dy = signal.scrollDelta.dy;
    if (dx != 0 && dx.abs() >= dy.abs()) {
      widget.onLevelDelta(dx < 0 ? -1 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: Colors.transparent,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerSignal: _handlePointerSignal,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => _levelDragDx = 0.0,
              onHorizontalDragUpdate: _handleLevelDragUpdate,
              onHorizontalDragEnd: (_) => _levelDragDx = 0.0,
              onHorizontalDragCancel: () => _levelDragDx = 0.0,
              child: InkWell(
                onTap: widget.onTap,
                splashColor: Colors.white.withOpacity(0.06),
                highlightColor: Colors.white.withOpacity(0.03),
                child: Container(
                  decoration: BoxDecoration(
                    color: card.color,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.06),
                      width: 0.8,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 10),
                      ),
                      BoxShadow(
                        color: Colors.white.withOpacity(0.04),
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.25),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child:
                                Icon(card.icon, color: Colors.white70, size: 22),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.22),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Text(
                              '레벨 ${card.selectedLevelIndex + 1}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              card.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            card.isIrregular
                                ? '반복: 비정기'
                                : '반복: ${card.repeatDays}일마다',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: card.isIrregular
                                  ? const Color(0xFFFBC47D)
                                  : Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Text(
                          card.selectedLevelText,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyActionCardPanel extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptyActionCardPanel({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF121A1D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.view_carousel_rounded, color: Colors.white38, size: 30),
            const SizedBox(height: 8),
            const Text(
              '행동 카드가 없습니다.',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '+ 버튼으로 첫 행동 카드를 만들어보세요.',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('행동 카드 만들기'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BehaviorCardDraft {
  final String name;
  final int repeatDays;
  final bool isIrregular;
  final List<String> levelContents;
  final IconData icon;

  const _BehaviorCardDraft({
    required this.name,
    required this.repeatDays,
    required this.isIrregular,
    required this.levelContents,
    required this.icon,
  });
}

class _BehaviorCardEditorDialog extends StatefulWidget {
  final _BehaviorCard? initialCard;

  const _BehaviorCardEditorDialog({this.initialCard});

  @override
  State<_BehaviorCardEditorDialog> createState() =>
      _BehaviorCardEditorDialogState();
}

class _BehaviorCardEditorDialogState extends State<_BehaviorCardEditorDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _repeatDaysCtrl;
  late final List<TextEditingController> _levelControllers;
  late IconData _selectedIcon;
  bool _isIrregular = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialCard;
    _nameCtrl = TextEditingController(text: initial?.name ?? '');
    _repeatDaysCtrl =
        TextEditingController(text: (initial?.repeatDays ?? 1).toString());

    final initialLevels = (initial?.levelContents.isNotEmpty ?? false)
        ? initial!.levelContents
        : const <String>[''];
    _levelControllers = [
      for (final content in initialLevels) TextEditingController(text: content),
    ];
    _selectedIcon = initial?.icon ?? _behaviorIconPack.first;
    _isIrregular = initial?.isIrregular ?? false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _repeatDaysCtrl.dispose();
    for (final ctrl in _levelControllers) {
      ctrl.dispose();
    }
    super.dispose();
  }

  InputDecoration _inputDecoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: kDlgTextSub),
      hintStyle: const TextStyle(color: Color(0xFF6E7E7E)),
      filled: true,
      fillColor: kDlgFieldBg,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDlgBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.redAccent),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.redAccent),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 2),
      child: Text(
        title,
        style: const TextStyle(
          color: kDlgText,
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  void _addLevelField() {
    setState(() {
      _levelControllers.add(TextEditingController());
    });
  }

  void _removeLevelField(int index) {
    if (_levelControllers.length <= 1) return;
    setState(() {
      final removed = _levelControllers.removeAt(index);
      removed.dispose();
    });
  }

  void _submit() {
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid) return;

    final repeatDays =
        (int.tryParse(_repeatDaysCtrl.text.trim()) ?? 1).clamp(1, 9999).toInt();
    final draft = _BehaviorCardDraft(
      name: _nameCtrl.text.trim(),
      repeatDays: repeatDays,
      isIrregular: _isIrregular,
      levelContents: _levelControllers.map((x) => x.text.trim()).toList(),
      icon: _selectedIcon,
    );
    Navigator.of(context).pop(draft);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initialCard != null;
    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kDlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: kDlgPanelBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDlgBorder),
                ),
                child: const Icon(Icons.view_carousel_rounded,
                    size: 17, color: kDlgTextSub),
              ),
              const SizedBox(width: 10),
              Text(
                isEdit ? '행동 카드 수정' : '행동 카드 생성',
                style: const TextStyle(
                  color: kDlgText,
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '반복 주기와 레벨별 내용을 설정해 행동 카드를 구성하세요.',
            style: TextStyle(
              color: kDlgTextSub,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: Form(
          key: _formKey,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 560),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('기본 정보'),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextFormField(
                          controller: _nameCtrl,
                          style: const TextStyle(
                            color: kDlgText,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: _inputDecoration('이름', hint: '예: 연산 복습'),
                          validator: (value) {
                            if ((value ?? '').trim().isEmpty) {
                              return '이름을 입력해 주세요.';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: AbsorbPointer(
                          absorbing: _isIrregular,
                          child: TextFormField(
                            controller: _repeatDaysCtrl,
                            style: const TextStyle(
                              color: kDlgText,
                              fontWeight: FontWeight.w600,
                            ),
                            readOnly: _isIrregular,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: _inputDecoration(
                              '반복 주기',
                              hint: '예: 2',
                            ),
                            validator: (value) {
                              if (_isIrregular) return null;
                              final text = (value ?? '').trim();
                              final parsed = int.tryParse(text);
                              if (parsed == null) {
                                return '숫자를 입력해 주세요.';
                              }
                              if (parsed < 1) {
                                return '1 이상이어야 합니다.';
                              }
                              return null;
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 104,
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: kDlgFieldBg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _isIrregular ? kDlgAccent : kDlgBorder,
                            width: 1.0,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Checkbox(
                              value: _isIrregular,
                              onChanged: (v) {
                                setState(() {
                                  _isIrregular = v ?? false;
                                  if (_repeatDaysCtrl.text.trim().isEmpty) {
                                    _repeatDaysCtrl.text = '1';
                                  }
                                });
                              },
                              activeColor: kDlgAccent,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: const VisualDensity(
                                horizontal: -4,
                                vertical: -4,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  setState(() {
                                    _isIrregular = !_isIrregular;
                                    if (_repeatDaysCtrl.text.trim().isEmpty) {
                                      _repeatDaysCtrl.text = '1';
                                    }
                                  });
                                },
                                child: Text(
                                  '비정기',
                                  style: TextStyle(
                                    color: _isIrregular ? kDlgText : kDlgTextSub,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _sectionTitle('아이콘 선택'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final icon in _behaviorIconPack)
                        InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => setState(() => _selectedIcon = icon),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: _selectedIcon.codePoint == icon.codePoint
                                  ? kDlgAccent.withOpacity(0.2)
                                  : kDlgPanelBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _selectedIcon.codePoint == icon.codePoint
                                    ? kDlgAccent
                                    : kDlgBorder,
                                width:
                                    _selectedIcon.codePoint == icon.codePoint
                                        ? 1.4
                                        : 1.0,
                              ),
                            ),
                            child: Icon(
                              icon,
                              size: 21,
                              color: _selectedIcon.codePoint == icon.codePoint
                                  ? Colors.white
                                  : kDlgTextSub,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: kDlgPanelBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kDlgBorder),
                    ),
                    child: Text(
                      _isIrregular
                          ? '비정기: 필요할 때만 수동으로 실행하는 행동입니다.'
                          : '반복 주기 의미: 1 = 매일, 2 = 2일마다 반복',
                      style: const TextStyle(
                        color: kDlgTextSub,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _sectionTitle('레벨별 내용'),
                  Row(
                    children: [
                      Text(
                        '총 ${_levelControllers.length}개 레벨',
                        style: const TextStyle(
                          color: kDlgTextSub,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      FilledButton.tonalIcon(
                        onPressed: _addLevelField,
                        icon: const Icon(Icons.add, size: 17),
                        label: const Text('레벨 추가'),
                        style: FilledButton.styleFrom(
                          backgroundColor: kDlgPanelBg,
                          foregroundColor: kDlgText,
                          side: const BorderSide(color: kDlgBorder),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (int i = 0; i < _levelControllers.length; i++) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      decoration: BoxDecoration(
                        color: kDlgPanelBg,
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: kDlgBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: kDlgFieldBg,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: kDlgBorder),
                                ),
                                child: Text(
                                  '레벨 ${i + 1}',
                                  style: const TextStyle(
                                    color: kDlgTextSub,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                onPressed: _levelControllers.length <= 1
                                    ? null
                                    : () => _removeLevelField(i),
                                tooltip: '레벨 삭제',
                                icon: const Icon(Icons.delete_outline_rounded),
                                iconSize: 18,
                                color: kDlgTextSub,
                                splashRadius: 18,
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          TextFormField(
                            controller: _levelControllers[i],
                            style: const TextStyle(color: kDlgText),
                            minLines: 2,
                            maxLines: 3,
                            decoration: _inputDecoration(
                              '내용',
                              hint: '이 레벨에서 수행할 행동 내용을 입력하세요.',
                            ),
                            validator: (value) {
                              if ((value ?? '').trim().isEmpty) {
                                return '레벨 내용은 비워둘 수 없습니다.';
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: kDlgAccent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          child: Text(isEdit ? '저장' : '생성'),
        ),
      ],
    );
  }
}
