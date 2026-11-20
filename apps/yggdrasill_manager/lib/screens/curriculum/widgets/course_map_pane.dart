import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../services/course_map_controller.dart';
import '../../../services/course_map_service.dart';
import '../../think/think_style.dart';
import 'concept_type_chip.dart';
import 'concept_workspace.dart';
import 'course_change_log_dialog.dart';

/// 기준 과정 탐색도(`docs/architecture/course-map.md`). 개념 탭과 문항로드맵 메뉴가 같은 컨트롤러를 쓴다.
/// 세로 레일과 단계 번호는 나열 순서만 뜻한다. 선수 관계로 읽히는 화살표는 쓰지 않는다.

const String _draftNote = '예전 문항로드맵 화면의 목록을 옮겨 온 기준 초안입니다. 공식 교육과정과 맞춰 본 자료가 아니며, 운영자가 고쳐 씁니다.';
const String _orderNote = '나열 순서(선수 관계 아님) · 왼쪽 숫자는 맨 아래 단원에 위에서부터 붙인 순서, 단원 번호도 순서로 셉니다.';

ButtonStyle _compactOutline() => thinkOutlineButton().copyWith(
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
      visualDensity: VisualDensity.compact,
    );

Widget _draftBadge() => const Tooltip(message: _draftNote, child: ThinkBadge('기준 초안', color: kThinkLink));

PopupMenuItem<String> _menuItem(String value, IconData icon, String label, {bool enabled = true, Color? color}) {
  final fg = !enabled ? kThinkHint : (color ?? kThinkText);
  return PopupMenuItem<String>(
    value: value,
    enabled: enabled,
    child: Row(
      children: [
        Icon(icon, size: 16, color: fg),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: fg, fontSize: 13)),
      ],
    ),
  );
}

String _levelName(int depth) => kCourseMapLevelNames[(depth - 1).clamp(0, 2)];

Widget _changeLogButton(
  BuildContext context,
  CourseMapController c,
  ValueChanged<String>? onOpenConcept,
) =>
    IconButton(
      key: const ValueKey('course-change-log'),
      tooltip: '최근 변경 기록',
      onPressed: () => unawaited(showCourseChangeLog(context, controller: c, onOpenConcept: onOpenConcept)),
      icon: const Icon(Icons.history, size: 18),
      color: kThinkSub,
    );

/// 크게 볼 때(편집).
class CourseMapPane extends StatefulWidget {
  const CourseMapPane({
    super.key,
    required this.controller,
    this.selectedConceptId,
    this.onOpenConcept,
    this.onOpenChange,
    this.aboveSelection,
    this.onShowLibrary,
  });

  final CourseMapController controller;

  /// 지금 고른 개념. 그 줄만 단원 선택과 같은 강조를 받는다.
  final ValueListenable<String?>? selectedConceptId;

  /// 옆 칸에서 선택한 단원보다 위에 둔다. 고른 개념 요약.
  final Widget? aboveSelection;

  /// 과정 관리 왼쪽 탭. 왼쪽 절반을 개념 라이브러리로 바꾼다.
  final VoidCallback? onShowLibrary;

  /// 흐름 목록의 개념 줄을 누르면 부른다. 없으면 개념 줄은 보기만 한다.
  final ValueChanged<String>? onOpenConcept;

  /// 최근 변경 기록에서 개념을 열 때. 없으면 [onOpenConcept]를 쓴다.
  final ValueChanged<String>? onOpenChange;

  @override
  State<CourseMapPane> createState() => _CourseMapPaneState();
}

class _CourseMapPaneState extends State<CourseMapPane> {
  final ScrollController _sideScroll = ScrollController();

  CourseMapController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _startLoading(_c);
  }

  @override
  void dispose() {
    _sideScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selectedConceptId;
    return ListenableBuilder(
      listenable: selected == null ? _c : Listenable.merge([_c, selected]),
      builder: (context, _) {
        final d = _c.draft;
        final dirty = d?.changeCount ?? 0;
        return ThinkPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConceptPaneHeader(
                icon: Icons.timeline,
                title: '교육과정 흐름',
                badges: [
                  _draftBadge(),
                  if (dirty > 0) ThinkBadge('저장 안 됨 $dirty', color: kThinkError),
                ],
                actions: [
                  _changeLogButton(context, _c, widget.onOpenChange ?? widget.onOpenConcept),
                  IconButton(
                    tooltip: '과정 목록 다시 읽기(편집은 남김)',
                    onPressed: _c.listLoading || _c.busy ? null : () => unawaited(_c.loadList()),
                    icon: const Icon(Icons.refresh, size: 18),
                    color: kThinkSub,
                  ),
                  TextButton.icon(
                    onPressed: !_c.listLoaded || _c.busy ? null : () => _createCourse(context, _c),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('과정 추가'),
                    style: TextButton.styleFrom(foregroundColor: kThinkAccent),
                  ),
                ],
              ),
              const Divider(color: kThinkBorder, height: 1),
              Expanded(child: _body()),
            ],
          ),
        );
      },
    );
  }

  Widget _body() {
    final problem = _listProblem(_c, compact: false);
    if (problem != null) return problem;
    if (_c.activeCourses.isEmpty) return _noCourses();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CourseStrip(controller: _c, withMenu: true, onShowLibrary: widget.onShowLibrary),
        const Divider(color: kThinkBorder, height: 1),
        Expanded(child: _courseBody()),
      ],
    );
  }

  Widget _noCourses() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.timeline, size: 40, color: kThinkAccent),
            const SizedBox(height: 16),
            const Text('살아 있는 과정이 없습니다',
                style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _c.busy ? null : () => _createCourse(context, _c),
                  style: thinkPrimaryButton(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('과정 추가'),
                ),
                if (_c.archivedCourses.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _showArchivedCourses(context, _c),
                    style: thinkOutlineButton(),
                    icon: const Icon(Icons.inventory_2_outlined, size: 16),
                    label: Text('보관한 과정 ${_c.archivedCourses.length}개'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _courseBody() {
    final course = _c.selectedCourse;
    if (course == null) return const SizedBox.shrink();
    final d = _c.draft;
    if (d == null) return _courseProblem(_c, course.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final outline = _CourseOutline(
                controller: _c,
                draft: d,
                editable: true,
                selectedConceptId: widget.selectedConceptId?.value,
                onOpenConcept: widget.onOpenConcept,
                onAcceptThink: (p) => unawaited(_acceptPlacement(p)),
                placementBusy: _locked || _c.placementBusyCourseId != null,
                onReorderPlacements: (unitId, ids) => unawaited(_reorderPlacements(unitId, ids)),
                onMovePlacementTo: (p, unitId) => unawaited(_dropMove(d, p, unitId)),
                onMovePlacement: (p) => unawaited(_movePlacement(d, p)),
                onRemovePlacement: (p) => unawaited(_removePlacement(p)),
              );
              final side = _side(d);
              if (constraints.maxWidth >= 760) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: outline),
                    const VerticalDivider(color: kThinkBorder, width: 1),
                    SizedBox(width: 320, child: side),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: outline),
                  const Divider(color: kThinkBorder, height: 1),
                  Expanded(flex: 2, child: side),
                ],
              );
            },
          ),
        ),
        const Divider(color: kThinkBorder, height: 1),
        _saveBar(d),
      ],
    );
  }

  bool get _locked => _c.busy;

  Widget _side(CourseMapDraft d) {
    final id = d.selectedId;
    return Scrollbar(
      controller: _sideScroll,
      child: ListView(
        key: const ValueKey('course-side-list'),
        controller: _sideScroll,
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.aboveSelection != null) ...[
            widget.aboveSelection!,
            const SizedBox(height: 16),
            const Divider(color: kThinkBorder, height: 1),
            const SizedBox(height: 12),
          ],
          if (id != null && d.node(id) != null) ...[
            ..._unitEditor(d, id),
          ] else ...[
            const ConceptSectionTitle('선택한 단원'),
            const ConceptHint('왼쪽에서 단원을 고르면 이름과 자리를 고치고, 그 단원에 놓인 개념을 볼 수 있습니다.'),
          ],
          const SizedBox(height: 16),
          const Divider(color: kThinkBorder, height: 1),
          const SizedBox(height: 12),
          ..._courseEditor(d),
          const SizedBox(height: 16),
          const Divider(color: kThinkBorder, height: 1),
          const SizedBox(height: 12),
          ..._archived(d),
        ],
      ),
    );
  }

  List<Widget> _unitEditor(CourseMapDraft d, String id) {
    final n = d.node(id)!;
    final depth = d.depthOf(id);
    final index = d.indexOf(id);
    final siblings = d.childrenOf(n.parentId).length;
    final path = [d.name.trim().isEmpty ? d.course.name : d.name.trim(), ...d.pathNames(id)];
    return [
      const ConceptSectionTitle('선택한 단원'),
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          ThinkBadge('${_levelName(depth)} ${d.numberLabel(id)}'),
          if (n.isNew) const ThinkBadge('새 단원 · 저장 전', color: kThinkAccent),
          if (d.isMoved(id)) const ThinkBadge('자리 바뀜', color: kThinkLink),
          if (d.isRenamed(id)) const ThinkBadge('이름 바뀜', color: kThinkLink),
        ],
      ),
      const SizedBox(height: 6),
      ConceptHint(path.join(' › ')),
      const SizedBox(height: 12),
      _NameField(
        key: ValueKey('unit-name-${identityHashCode(d)}-$id'),
        initial: n.name,
        label: '이름',
        maxLength: kCourseMapNameMax,
        enabled: !_locked,
        onChanged: (v) => _c.rename(id, v),
      ),
      const SizedBox(height: 4),
      ..._conceptAddButton(d, id),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _locked || index <= 0 ? null : () => _c.moveUnit(id, -1),
            style: _compactOutline(),
            icon: const Icon(Icons.arrow_upward, size: 16),
            label: const Text('위로'),
          ),
          OutlinedButton.icon(
            onPressed: _locked || index >= siblings - 1 ? null : () => _c.moveUnit(id, 1),
            style: _compactOutline(),
            icon: const Icon(Icons.arrow_downward, size: 16),
            label: const Text('아래로'),
          ),
          OutlinedButton.icon(
            onPressed: _locked ? null : () => _move(d, id),
            style: _compactOutline(),
            icon: const Icon(Icons.drive_file_move_outline, size: 16),
            label: const Text('옮기기'),
          ),
          OutlinedButton.icon(
            onPressed: _locked ? null : () => _c.addUnit(n.parentId, after: id),
            style: _compactOutline(),
            icon: const Icon(Icons.playlist_add, size: 16),
            label: Text('${_levelName(depth)} 추가'),
          ),
          if (depth < kCourseMapMaxDepth)
            OutlinedButton.icon(
              onPressed: _locked ? null : () => _c.addUnit(id),
              style: _compactOutline(),
              icon: const Icon(Icons.subdirectory_arrow_right, size: 16),
              label: Text('아래에 ${_levelName(depth + 1)} 추가'),
            ),
          TextButton.icon(
            onPressed: _locked ? null : () => _remove(d, id),
            style: TextButton.styleFrom(foregroundColor: kThinkError),
            icon: const Icon(Icons.archive_outlined, size: 16),
            label: Text(d.subtree(id).every((x) => d.node(x)!.isNew) ? '빼기' : '보관'),
          ),
        ],
      ),
      ..._conceptStatus(d, id),
    ];
  }

  /// 넣을 수 있을 때만, 단원 이동·추가 버튼보다 위에 둔다.
  List<Widget> _conceptAddButton(CourseMapDraft d, String unitId) {
    final n = d.node(unitId)!;
    final courseId = d.course.id;
    if (n.isNew || _c.placementError(courseId) != null || _c.placementsOf(courseId) == null) {
      return const [];
    }
    final busy = _locked || _c.placementBusyCourseId != null;
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('placement-add'),
          onPressed: busy ? null : () => _addConcepts(d, unitId),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('개념 추가'),
          style: TextButton.styleFrom(foregroundColor: kThinkAccent, visualDensity: VisualDensity.compact),
        ),
      ),
      const SizedBox(height: 8),
    ];
  }

  /// 배치를 아직 넣지 못할 때의 안내. 넣을 수 있으면 비운다.
  List<Widget> _conceptStatus(CourseMapDraft d, String unitId) {
    final n = d.node(unitId)!;
    final courseId = d.course.id;
    final error = _c.placementError(courseId);
    final loaded = _c.placementsOf(courseId) != null;
    if (n.isNew) {
      return const [
        SizedBox(height: 8),
        ConceptHint('저장 전 새 단원입니다. 저장한 뒤에 개념을 넣을 수 있습니다.'),
      ];
    }
    if (error != null) {
      return [
        const SizedBox(height: 8),
        ThinkNotice(
          text: error.notReady
              ? 'DB에 개념 배치 기능이 아직 반영되지 않았습니다. 마이그레이션은 별도 승인 뒤에 반영합니다.'
              : '놓인 개념을 읽지 못했습니다: ${error.message}',
          color: error.notReady ? kThinkBlue : kThinkError,
          icon: error.notReady ? Icons.info_outline : Icons.error_outline,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _c.placementLoading(courseId) ? null : () => unawaited(_c.loadPlacements(courseId)),
            style: _compactOutline(),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('다시 읽기'),
          ),
        ),
      ];
    }
    if (!loaded) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(color: kThinkAccent, backgroundColor: kThinkBorder, minHeight: 2),
        ),
      ];
    }
    return const [];
  }

  List<Widget> _courseEditor(CourseMapDraft d) {
    final c = d.course;
    final placed = _c.placementsOf(c.id);
    final o = _c.overview;
    return [
      const ConceptSectionTitle('과정 정보'),
      _NameField(
        key: ValueKey('course-name-${identityHashCode(d)}'),
        initial: d.name,
        label: '과정 이름',
        maxLength: kCourseMapCourseNameMax,
        enabled: !_locked,
        onChanged: _c.setCourseName,
      ),
      const SizedBox(height: 4),
      const Text('학교급', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final level in kCourseMapSchoolLevels)
            ThinkToggleChip(
              label: level,
              icon: Icons.school_outlined,
              selected: d.schoolLevel == level,
              enabled: !_locked,
              onChanged: (_) => _c.setSchoolLevel(level),
            ),
        ],
      ),
      const SizedBox(height: 12),
      _CurriculumField(
        value: d.curriculumCode,
        enabled: !_locked,
        onChanged: _c.setCurriculumCode,
      ),
      const SizedBox(height: 8),
      if (c.courseKey != null) ConceptHint('교재 과정 키: ${c.courseKey}'),
      ConceptHint('판 v${c.version} · ${formatDateTime(c.updatedAt)} 저장'),
      if (c.seeded) const ConceptHint('처음 자료: 예전 문항로드맵 화면의 목록(이름·계층·순서 그대로).'),
      if (placed != null) ...[
        const SizedBox(height: 8),
        ConceptHint('이 과정 단원에 놓인 개념 자리 ${placed.length}곳'
            '${o == null ? '' : ' · 라이브러리 개념 ${o.concepts}개 중 ${o.placed}개가 어느 과정에든 놓임'}'),
      ],
      const ConceptHint('Think 대화에서 "이 과정에 개념을 배치해 줘"처럼 부탁하면 카드로 제안합니다. 승인한 항목만 반영됩니다.'),
    ];
  }

  Future<void> _addConcepts(CourseMapDraft d, String unitId) async {
    final courseId = d.course.id;
    final elsewhere = <String, List<String>>{};
    for (final p in _c.placementsOf(courseId) ?? const <CourseMapPlacement>[]) {
      if (p.unitId != unitId && d.node(p.unitId) != null) {
        (elsewhere[p.conceptId] ??= []).add(d.numberLabel(p.unitId));
      }
    }
    final ids = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _ConceptPickDialog(
        controller: _c,
        unitName: d.node(unitId)!.name.trim(),
        here: {for (final p in _c.placementsIn(courseId, unitId)) p.conceptId},
        elsewhere: elsewhere,
      ),
    );
    if (ids == null || ids.isEmpty || !mounted) return;
    final problem = await _c.addPlacements(unitId, ids);
    if (!mounted) return;
    showThinkSnack(context, problem ?? '개념 ${ids.length}개를 넣었습니다.', error: problem != null);
  }

  Future<void> _reorderPlacements(String unitId, List<String> ids) async {
    final problem = await _c.reorderPlacements(unitId, ids);
    if (problem != null && mounted) showThinkSnack(context, problem, error: true);
  }

  Future<void> _acceptPlacement(CourseMapPlacement p) async {
    final problem = await _c.acceptPlacement(p.id);
    if (!mounted) return;
    showThinkSnack(context, problem ?? '확인했습니다.', error: problem != null);
  }

  Future<void> _movePlacement(CourseMapDraft d, CourseMapPlacement p) async {
    final taken = {
      for (final x in _c.placementsOf(d.course.id) ?? const <CourseMapPlacement>[])
        if (x.conceptId == p.conceptId) x.unitId,
    };
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => _PlacementMoveDialog(draft: d, placement: p, taken: taken),
    );
    if (target == null || !mounted) return;
    final problem = await _c.movePlacement(p.id, target);
    if (!mounted) return;
    _snackMove(d, p, target, problem);
  }

  Future<void> _dropMove(CourseMapDraft d, CourseMapPlacement p, String unitId) async {
    final node = d.node(unitId);
    if (node == null || unitId == p.unitId) return;
    if (node.isNew) {
      showThinkSnack(context, '저장 전 새 단원입니다. 저장한 뒤에 옮길 수 있습니다.', error: true);
      return;
    }
    final taken = {
      for (final x in _c.placementsOf(d.course.id) ?? const <CourseMapPlacement>[])
        if (x.conceptId == p.conceptId) x.unitId,
    };
    if (taken.contains(unitId)) {
      showThinkSnack(context, '이 개념이 이미 놓인 단원입니다.', error: true);
      return;
    }
    final problem = await _c.movePlacement(p.id, unitId);
    if (!mounted) return;
    _snackMove(d, p, unitId, problem);
  }

  void _snackMove(CourseMapDraft d, CourseMapPlacement p, String unitId, String? problem) {
    showThinkSnack(context, problem ?? '"${p.name}"을(를) ${d.numberLabel(unitId)} 단원으로 옮겼습니다.',
        error: problem != null);
  }

  Future<void> _removePlacement(CourseMapPlacement p) async {
    final ok = await confirmThink(
      context,
      title: '이 단원에서 빼기',
      message: '"${p.name}"을(를) 이 단원에서 뺍니다.\n'
          '개념은 라이브러리에 그대로 있고, 다른 단원에 놓인 자리와 출처도 그대로입니다.',
      confirmLabel: '빼기',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final problem = await _c.removePlacement(p.id);
    if (!mounted) return;
    showThinkSnack(context, problem ?? '"${p.name}"을(를) 뺐습니다.', error: problem != null);
  }

  List<Widget> _archived(CourseMapDraft d) {
    final list = d.base.archived;
    return [
      ConceptSectionTitle('보관한 단원 (${list.length})'),
      if (d.archive.isNotEmpty) ...[
        ThinkNotice(
          text: '저장하면 단원 ${d.archive.length}개를 보관합니다(지우지 않음).',
          color: kThinkAccent,
          icon: Icons.archive_outlined,
        ),
        const SizedBox(height: 8),
      ],
      if (list.isEmpty)
        const ConceptHint('보관한 단원이 없습니다. 보관한 단원은 지우지 않고 여기서 되살릴 수 있습니다.')
      else ...[
        for (final a in list) ...[
          _ArchivedUnitTile(
            unit: a,
            blockedReason: !a.parentActive
                ? '위 단원이 보관돼 있습니다. 위 단원을 먼저 되살리세요.'
                : d.dirty
                    ? '저장하지 않은 편집이 있습니다. 저장하거나 되돌린 뒤 되살리세요.'
                    : null,
            busy: _locked,
            onRestore: () => _restore(a),
          ),
          const SizedBox(height: 8),
        ],
      ],
    ];
  }

  Widget _saveBar(CourseMapDraft d) {
    final id = d.course.id;
    final saving = _c.busyCourseId == id;
    final error = _c.saveError(id);
    final n = d.changeCount;
    final Widget status;
    if (saving) {
      status = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent)),
          SizedBox(width: 8),
          Text('저장하는 중…', style: TextStyle(color: kThinkSub, fontSize: 13)),
        ],
      );
    } else if (n > 0) {
      status = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.circle, size: 8, color: kThinkError),
          const SizedBox(width: 8),
          Text('저장 안 한 변경 $n곳', style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
          if (d.archive.isNotEmpty)
            Flexible(
              child: Text(' · 저장하면 단원 ${d.archive.length}개 보관',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kThinkSub, fontSize: 12)),
            ),
        ],
      );
    } else {
      status = Text('저장됨 · v${d.course.version} · ${formatDateTime(d.course.updatedAt)}',
          style: const TextStyle(color: kThinkHint, fontSize: 12));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error != null && !saving) ...[
            ThinkNotice(text: '저장하지 못했습니다: ${error.message}', color: kThinkError, icon: Icons.error_outline),
            if (error.stale || error.code == 'course_map_unit_missing') ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _locked ? null : () => _reloadLatest(id),
                  style: _compactOutline(),
                  icon: const Icon(Icons.sync, size: 16),
                  label: const Text('최신 저장본 불러오기(지금 편집 버림)'),
                ),
              ),
            ],
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(child: Align(alignment: Alignment.centerLeft, child: status)),
              if (n > 0)
                TextButton(
                  onPressed: _locked ? null : _discard,
                  style: TextButton.styleFrom(foregroundColor: kThinkSub),
                  child: const Text('되돌리기'),
                ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: n > 0 && !_locked ? _save : null,
                style: thinkPrimaryButton(),
                icon: const Icon(Icons.save_outlined, size: 16),
                label: const Text('저장'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final ok = await _c.save();
    if (ok && mounted) showThinkSnack(context, '과정 탐색도를 저장했습니다.');
  }

  Future<void> _discard() async {
    final n = _c.draft?.changeCount ?? 0;
    final ok = await confirmThink(
      context,
      title: '편집 되돌리기',
      message: '저장하지 않은 변경 $n곳을 버리고 마지막 저장본으로 돌아갑니다.',
      confirmLabel: '되돌리기',
      destructive: true,
    );
    if (ok) _c.discard();
  }

  Future<void> _reloadLatest(String courseId) async {
    final ok = await confirmThink(
      context,
      title: '최신 저장본 불러오기',
      message: '지금 편집을 버리고 서버의 최신 저장본을 불러옵니다.',
      confirmLabel: '불러오기',
      destructive: true,
    );
    if (ok) await _c.loadCourse(courseId);
  }

  Future<void> _move(CourseMapDraft d, String id) async {
    final target = await showDialog<_MoveTarget>(
      context: context,
      builder: (ctx) => _MoveDialog(draft: d, id: id),
    );
    if (target == null || !mounted) return;
    final why = _c.reparent(id, target.parentId);
    if (why != null) showThinkSnack(context, why, error: true);
  }

  Future<void> _remove(CourseMapDraft d, String id) async {
    final ids = d.subtree(id);
    final saved = ids.where((x) => !d.node(x)!.isNew).length;
    final fresh = ids.length - saved;
    final name = d.node(id)!.name.trim();
    if (saved == 0) {
      _c.removeUnit(id);
      showThinkSnack(context, '저장 전 새 단원이라 바로 뺐습니다.');
      return;
    }
    final more = ids.length > 1 ? '과(와) 아래 단원 ${ids.length - 1}개' : '';
    final ok = await confirmThink(
      context,
      title: '단원 보관',
      message: '"$name"$more를 보관합니다.\n'
          '저장하면 목록에서 빠지고, "보관한 단원"에서 되살릴 수 있습니다. 지우지는 않습니다.'
          '${fresh > 0 ? '\n저장 전 새 단원 $fresh개는 바로 없어집니다.' : ''}',
      confirmLabel: '보관',
      destructive: true,
    );
    if (ok) _c.removeUnit(id);
  }

  Future<void> _restore(CourseMapArchivedUnit a) async {
    final problem = await _c.restoreUnit(a.id);
    if (!mounted) return;
    showThinkSnack(context, problem ?? '"${a.name}"을(를) 되살렸습니다.', error: problem != null);
  }
}

/// 다른 쪽을 크게 볼 때(읽기만).
class CourseMapSummaryPane extends StatefulWidget {
  const CourseMapSummaryPane({
    super.key,
    required this.controller,
    this.selectedConceptId,
    this.onExpand,
    this.onOpenConcept,
    this.onOpenChange,
  });

  final CourseMapController controller;

  /// 지금 고른 개념. 그 줄만 단원 선택과 같은 강조를 받는다.
  final ValueListenable<String?>? selectedConceptId;

  final VoidCallback? onExpand;
  final ValueChanged<String>? onOpenConcept;

  /// 최근 변경 기록에서 개념을 열 때. 없으면 [onOpenConcept]를 쓴다.
  final ValueChanged<String>? onOpenChange;

  @override
  State<CourseMapSummaryPane> createState() => _CourseMapSummaryPaneState();
}

class _CourseMapSummaryPaneState extends State<CourseMapSummaryPane> {
  CourseMapController get _c => widget.controller;

  Future<void> _acceptThink(CourseMapPlacement p) async {
    final problem = await _c.acceptPlacement(p.id);
    if (!mounted) return;
    showThinkSnack(context, problem ?? '확인했습니다.', error: problem != null);
  }

  @override
  void initState() {
    super.initState();
    _startLoading(_c);
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selectedConceptId;
    return ListenableBuilder(
      listenable: selected == null ? _c : Listenable.merge([_c, selected]),
      builder: (context, _) => ThinkPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConceptPaneHeader(
              icon: Icons.timeline,
              title: '교육과정 흐름',
              badges: [_draftBadge()],
              actions: [_changeLogButton(context, _c, widget.onOpenChange ?? widget.onOpenConcept)],
              onExpand: widget.onExpand,
            ),
            const Divider(color: kThinkBorder, height: 1),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final problem = _listProblem(_c, compact: true);
    if (problem != null) return problem;
    if (_c.activeCourses.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: ConceptHint('살아 있는 과정이 없습니다. 크게 보기에서 과정을 추가할 수 있습니다.'),
      );
    }
    final course = _c.selectedCourse;
    final d = _c.draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CourseStrip(controller: _c, withMenu: false),
        const Divider(color: kThinkBorder, height: 1),
        if (d != null && d.dirty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: ThinkNotice(
              text: '저장하지 않은 변경 ${d.changeCount}곳 — 크게 보기에서 저장하세요.',
              color: kThinkAccent,
              icon: Icons.edit_note,
            ),
          ),
        Expanded(
          child: course == null
              ? const SizedBox.shrink()
              : d == null
                  ? _courseProblem(_c, course.id)
                  : _CourseOutline(
                      controller: _c,
                      draft: d,
                      editable: false,
                      selectedConceptId: widget.selectedConceptId?.value,
                      onOpenConcept: widget.onOpenConcept,
                      onAcceptThink: (p) => unawaited(_acceptThink(p)),
                    ),
        ),
      ],
    );
  }
}

/// 창 닫기·로그아웃 전에 부른다. 저장 안 한 과정 편집이 없으면 묻지 않고 true.
Future<bool> confirmDiscardCourseMapEdits(BuildContext context, CourseMapController c, {required String action}) {
  final names = c.dirtyCourseNames;
  if (names.isEmpty) return Future.value(true);
  return confirmThink(
    context,
    title: '저장하지 않은 과정 편집',
    message: '교육과정 흐름에 저장하지 않은 편집이 있습니다: ${names.join(', ')}.\n$action 이 편집은 사라집니다.',
    confirmLabel: '버리고 계속',
    destructive: true,
  );
}

/// 다른 칸이 이미 듣고 있을 수 있어 빌드가 끝난 뒤 읽는다.
void _startLoading(CourseMapController c) {
  c.ensureStarted();
  scheduleMicrotask(() {
    if (!c.listLoaded && !c.listLoading && c.listError == null) unawaited(c.loadList());
  });
}

/// 목록을 아직 못 읽었을 때. 읽은 적이 없으면 다른 목록으로 대신 보이지 않는다.
Widget? _listProblem(CourseMapController c, {required bool compact}) {
  if (c.listLoaded) return null;
  final error = c.listError;
  if (c.listLoading || error == null) {
    return const Center(child: CircularProgressIndicator(color: kThinkAccent));
  }
  return Center(
    child: SingleChildScrollView(
      padding: EdgeInsets.all(compact ? 16 : 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ThinkNotice(
            text: '과정 목록을 읽지 못했습니다: ${error.message}',
            color: error.notReady ? kThinkBlue : kThinkError,
            icon: error.notReady ? Icons.info_outline : Icons.error_outline,
          ),
          if (error.notReady) ...[
            const SizedBox(height: 8),
            const ConceptHint('DB 반영(마이그레이션)은 별도 승인 뒤에 합니다. 반영 전에는 과정 흐름을 볼 수 없고, '
                '개념 라이브러리와 Think 대화는 그대로 쓸 수 있습니다.'),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => unawaited(c.loadList()),
              style: thinkOutlineButton(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('다시 불러오기'),
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _courseProblem(CourseMapController c, String courseId) {
  final error = c.courseError(courseId);
  if (error == null || c.courseLoading(courseId)) {
    return const Center(child: CircularProgressIndicator(color: kThinkAccent));
  }
  return Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ThinkNotice(text: '이 과정을 읽지 못했습니다: ${error.message}', color: kThinkError, icon: Icons.error_outline),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => unawaited(c.loadCourse(courseId)),
              style: thinkOutlineButton(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('다시 읽기'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CourseStrip extends StatefulWidget {
  const _CourseStrip({required this.controller, required this.withMenu, this.onShowLibrary});

  final CourseMapController controller;
  final bool withMenu;
  final VoidCallback? onShowLibrary;

  @override
  State<_CourseStrip> createState() => _CourseStripState();
}

class _CourseStripState extends State<_CourseStrip> {
  final ScrollController _scroll = ScrollController();

  CourseMapController get _c => widget.controller;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _c.activeCourses;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    for (final c in active) ...[
                      _CourseChip(
                        course: c,
                        selected: c.id == _c.selectedCourseId,
                        dirty: _c.isDirty(c.id),
                        onTap: () => _c.selectCourse(c.id),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (widget.onShowLibrary != null) ...[
            OutlinedButton.icon(
              key: const ValueKey('course-show-library'),
              onPressed: _c.busy ? null : widget.onShowLibrary,
              style: _compactOutline(),
              icon: const Icon(Icons.account_tree_outlined, size: 16),
              label: const Text('개념 라이브러리'),
            ),
            const SizedBox(width: 4),
          ],
          if (widget.withMenu) _menu(active),
        ],
      ),
    );
  }

  Widget _menu(List<CourseMapCourse> active) {
    final selected = _c.selectedCourse;
    final i = selected == null ? -1 : active.indexWhere((c) => c.id == selected.id);
    final archived = _c.archivedCourses.length;
    return PopupMenuButton<String>(
      tooltip: '과정 관리',
      enabled: !_c.busy,
      color: kThinkPanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kThinkBorder)),
      icon: const Icon(Icons.more_horiz, size: 20, color: kThinkSub),
      onSelected: (v) => unawaited(_onMenu(v, selected)),
      itemBuilder: (context) => [
        _menuItem('add', Icons.add, '과정 추가'),
        _menuItem('up', Icons.arrow_back, '이 과정 앞으로', enabled: i > 0),
        _menuItem('down', Icons.arrow_forward, '이 과정 뒤로', enabled: i >= 0 && i < active.length - 1),
        _menuItem('archive', Icons.archive_outlined, '이 과정 보관', enabled: selected != null, color: kThinkError),
        _menuItem('archived', Icons.inventory_2_outlined, '보관한 과정 $archived개', enabled: archived > 0),
      ],
    );
  }

  Future<void> _onMenu(String value, CourseMapCourse? selected) async {
    String? problem;
    switch (value) {
      case 'add':
        await _createCourse(context, _c);
        return;
      case 'archived':
        await _showArchivedCourses(context, _c);
        return;
      case 'up':
      case 'down':
        if (selected == null) return;
        problem = await _c.moveCourse(selected.id, value == 'up' ? -1 : 1);
      case 'archive':
        if (selected == null) return;
        final ok = await confirmThink(
          context,
          title: '과정 보관',
          message: '"${selected.name}" 과정을 목록에서 뺍니다. 단원은 지우지 않고, "보관한 과정"에서 되살릴 수 있습니다.',
          confirmLabel: '보관',
          destructive: true,
        );
        if (!ok) return;
        problem = await _c.archiveCourse(selected.id);
        if (problem == null && mounted) showThinkSnack(context, '"${selected.name}" 과정을 보관했습니다.');
    }
    if (problem != null && mounted) showThinkSnack(context, problem, error: true);
  }
}

class _CourseChip extends StatelessWidget {
  const _CourseChip({required this.course, required this.selected, required this.dirty, required this.onTap});

  final CourseMapCourse course;
  final bool selected;
  final bool dirty;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? kThinkAccent : kThinkSub;
    final counts = course.counts;
    return Tooltip(
      message: '대 ${counts[0]} · 중 ${counts[1]} · 소 ${counts[2]}${dirty ? ' · 저장 안 한 편집 있음' : ''}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: selected ? kThinkAccent.withValues(alpha: 0.5) : kThinkBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(course.name, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
                if (dirty) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.circle, size: 6, color: kThinkError),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Row {
  const _Row(this.id, this.depth, [this.placement]);

  /// 단원. 개념 줄이면 그 개념이 놓인 단원.
  final String id;
  final int depth;
  final CourseMapPlacement? placement;
}

/// 대·중·소 목록과 왼쪽 나열 순서 레일. 단원 아래에 놓인 개념 줄을 펼쳐 볼 수 있다.
class _CourseOutline extends StatefulWidget {
  const _CourseOutline({
    required this.controller,
    required this.draft,
    required this.editable,
    this.selectedConceptId,
    this.onOpenConcept,
    this.onAcceptThink,
    this.placementBusy = false,
    this.onReorderPlacements,
    this.onMovePlacementTo,
    this.onMovePlacement,
    this.onRemovePlacement,
  });

  final CourseMapController controller;
  final CourseMapDraft draft;
  final bool editable;
  final String? selectedConceptId;
  final ValueChanged<String>? onOpenConcept;
  final ValueChanged<CourseMapPlacement>? onAcceptThink;
  final bool placementBusy;
  final void Function(String unitId, List<String> ids)? onReorderPlacements;
  final void Function(CourseMapPlacement placement, String unitId)? onMovePlacementTo;
  final void Function(CourseMapPlacement placement)? onMovePlacement;
  final void Function(CourseMapPlacement placement)? onRemovePlacement;

  @override
  State<_CourseOutline> createState() => _CourseOutlineState();
}

class _CourseOutlineState extends State<_CourseOutline> {
  static const double _unitHeight = 36;
  static const double _conceptHeight = 32;

  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _hitKeys = {};
  String? _dragId;
  String? _hoverPlacementId;
  String? _hoverUnitId;

  GlobalKey _hitKey(String id) => _hitKeys.putIfAbsent(id, GlobalKey.new);

  Duration get _shiftDuration {
    final disabled = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return disabled ? Duration.zero : const Duration(milliseconds: 180);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<_Row> _visible(CourseMapDraft d, CourseMapController c) {
    final courseId = d.course.id;
    final out = <_Row>[];
    void walk(String id, int depth) {
      out.add(_Row(id, depth));
      if (c.conceptsOpen(courseId, id)) {
        for (final p in c.placementsIn(courseId, id)) {
          out.add(_Row(id, depth, p));
        }
      }
      if (!d.expanded.contains(id)) return;
      for (final k in d.childrenOf(id)) {
        walk(k, depth + 1);
      }
    }

    for (final r in d.childrenOf(null)) {
      walk(r, 1);
    }
    return out;
  }

  /// 끌어 놓은 자리. 개념 줄이면 그 개념, 단원 줄이면 그 단원.
  _Row? _rowAt(Offset global, List<_Row> rows) {
    for (final row in rows) {
      final id = row.placement == null ? 'u:${row.id}' : 'p:${row.placement!.id}';
      final box = _hitKey(id).currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(global)) return row;
    }
    return null;
  }

  void _dropConcept(CourseMapPlacement p, Offset global, List<_Row> rows) {
    final hit = _rowAt(global, rows);
    if (hit == null) return;
    final onto = hit.placement;
    if (onto != null && onto.unitId == p.unitId) {
      if (onto.id == p.id) return;
      final ids = [for (final x in widget.controller.placementsIn(widget.draft.course.id, p.unitId)) x.id];
      final from = ids.indexOf(p.id);
      final to = ids.indexOf(onto.id);
      if (from < 0 || to < 0) return;
      final moved = ids.removeAt(from);
      ids.insert(to, moved);
      widget.onReorderPlacements?.call(p.unitId, ids);
      return;
    }
    final unitId = onto?.unitId ?? hit.id;
    if (unitId == p.unitId) return;
    widget.onMovePlacementTo?.call(p, unitId);
  }

  /// 아래로 끌면 대상 뒤에, 위로 끌면 대상 앞에 빈 칸을 연다. 놓는 순서와 같다.
  (bool, bool) _gapFor(CourseMapPlacement p) {
    if (_dragId == null || _dragId == p.id) return (false, false);
    if (_hoverPlacementId == p.id) {
      final ids = [for (final x in widget.controller.placementsIn(widget.draft.course.id, p.unitId)) x.id];
      final from = ids.indexOf(_dragId!);
      final to = ids.indexOf(p.id);
      if (from < 0 || to < 0 || from == to) return (false, false);
      return (from > to, from < to);
    }
    if (_hoverUnitId == p.unitId) {
      final ids = [for (final x in widget.controller.placementsIn(widget.draft.course.id, p.unitId)) x.id];
      if (ids.isNotEmpty && ids.last == p.id) return (false, true);
    }
    return (false, false);
  }

  void _hover(CourseMapPlacement p, Offset global, List<_Row> rows) {
    final hit = _rowAt(global, rows);
    String? placementId;
    String? unitId;
    if (hit != null) {
      final onto = hit.placement;
      if (onto != null && onto.id != p.id) {
        if (onto.unitId == p.unitId) {
          placementId = onto.id;
        } else {
          unitId = onto.unitId;
        }
      } else if (onto == null && hit.id != p.unitId) {
        unitId = hit.id;
      }
    }
    if (_dragId == p.id && _hoverPlacementId == placementId && _hoverUnitId == unitId) return;
    setState(() {
      _dragId = p.id;
      _hoverPlacementId = placementId;
      _hoverUnitId = unitId;
    });
  }

  void _clearDrag() {
    if (_dragId == null && _hoverPlacementId == null && _hoverUnitId == null) return;
    setState(() {
      _dragId = null;
      _hoverPlacementId = null;
      _hoverUnitId = null;
    });
  }

  /// 놓일 자리만큼 칸을 늘려 아래 줄이 밀리게 한다. 끄는 줄 높이는 그대로 둔다.
  Widget _shiftSlot({
    required String? hitId,
    required double base,
    required bool gapBefore,
    required bool gapAfter,
    required Widget child,
  }) {
    final open = gapBefore || gapAfter;
    final before = gapBefore && !gapAfter;
    final slot = AnimatedContainer(
      duration: _shiftDuration,
      curve: Curves.easeOutCubic,
      height: open ? base + _conceptHeight : base,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final extra = math.max(0.0, constraints.maxHeight - base);
            return Stack(
              fit: StackFit.expand,
              children: [
                if (extra > 0.5)
                  Positioned(
                    key: const ValueKey('concept-drop-gap'),
                    left: 56,
                    right: 8,
                    top: before ? 0 : base,
                    height: extra,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: kThinkAccent.withValues(alpha: 0.16),
                        borderRadius: const BorderRadius.all(Radius.circular(8)),
                        border: Border.all(color: kThinkAccent.withValues(alpha: 0.6)),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: before ? extra : 0,
                  height: base,
                  child: child,
                ),
              ],
            );
          },
        ),
      ),
    );
    if (hitId == null) return slot;
    return KeyedSubtree(key: _hitKey(hitId), child: slot);
  }

  Widget _row(CourseMapDraft d, List<_Row> rows, int i, Map<String, (int, int)> steps,
      Map<String, CourseUnitTally> tallies, bool compact) {
    final c = widget.controller;
    final courseId = d.course.id;
    final r = rows[i];
    final last = i == rows.length - 1;
    final p = r.placement;
    final open = widget.onOpenConcept;
    final arrange = widget.editable && widget.onReorderPlacements != null;
    if (p != null) {
      Widget conceptRow() => _ConceptRow(
            placement: p,
            depth: r.depth,
            last: last,
            selected: p.conceptId == widget.selectedConceptId,
            onOpen: open == null ? null : () => open(p.conceptId),
            onAccept: p.byThink ? () => widget.onAcceptThink?.call(p) : null,
            onMove: arrange ? () => widget.onMovePlacement?.call(p) : null,
            onRemove: arrange ? () => widget.onRemovePlacement?.call(p) : null,
            busy: widget.placementBusy,
          );
      final gap = arrange ? _gapFor(p) : (false, false);
      return _shiftSlot(
        hitId: arrange ? 'p:${p.id}' : null,
        base: _conceptHeight,
        gapBefore: gap.$1,
        gapAfter: gap.$2,
        child: arrange
            ? _HoldToDrag(
                key: ValueKey('hold-${p.id}'),
                enabled: !widget.placementBusy,
                onDrop: (global) => _dropConcept(p, global, rows),
                onDragUpdate: (global) => _hover(p, global, rows),
                onDragEnd: _clearDrag,
                buildChild: conceptRow,
              )
            : conceptRow(),
      );
    }
    final hasKids = d.childrenOf(r.id).isNotEmpty;
    final concepts = c.placementCount(courseId, r.id);
    final conceptsOpen = c.conceptsOpen(courseId, r.id);
    final hoverHere = arrange && _hoverUnitId == r.id;
    final unit = _UnitRow(
      draft: d,
      row: r,
      step: steps[r.id] ?? (0, 0),
      first: i == 0,
      last: last,
      selected: r.id == d.selectedId,
      dropTarget: hoverHere,
      editable: widget.editable,
      concepts: concepts,
      conceptsOpen: conceptsOpen,
      tally: hasKids ? tallies[r.id] : null,
      compact: compact,
      onTap: () {
        c.selectUnit(r.id);
        if (!widget.editable && !hasKids && concepts > 0) c.toggleConcepts(courseId, r.id);
      },
      onToggle: () => c.toggleExpanded(r.id),
      onToggleConcepts: () => c.toggleConcepts(courseId, r.id),
    );
    return _shiftSlot(
      hitId: arrange ? 'u:${r.id}' : null,
      base: _unitHeight,
      gapBefore: false,
      gapAfter: hoverHere && (!conceptsOpen || concepts == 0),
      child: unit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final c = widget.controller;
    final courseId = d.course.id;
    final placements = c.placementsOf(courseId);
    final tallies = placements == null ? const <String, CourseUnitTally>{} : courseUnitTallies(d, placements);
    final anyPlaced = placements != null && placements.any((p) => d.node(p.unitId) != null);
    final conceptsOpen = c.allConceptsOpen(courseId);
    final rows = _visible(d, c);
    final steps = d.steps();
    final allOpen = d.flatIds().where((id) => d.childrenOf(id).isNotEmpty).every(d.expanded.contains);
    final buttonStyle = TextButton.styleFrom(foregroundColor: kThinkSub, visualDensity: VisualDensity.compact);
    final buttons = <Widget>[
      if (d.unitCount > 0)
        TextButton(
          onPressed: () => c.setAllExpanded(!allOpen),
          style: buttonStyle,
          child: Text(allOpen ? '모두 접기' : '모두 펼치기'),
        ),
      if (anyPlaced)
        TextButton(
          key: const ValueKey('outline-concepts-all'),
          onPressed: () => c.setAllConceptsOpen(courseId, !conceptsOpen),
          style: buttonStyle,
          child: Text(conceptsOpen ? '개념 접기' : '개념 펼치기'),
        ),
      if (widget.editable)
        TextButton.icon(
          onPressed: c.busy ? null : () => c.addUnit(null),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('대단원 추가'),
          style: TextButton.styleFrom(foregroundColor: kThinkAccent, visualDensity: VisualDensity.compact),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 420;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, widget.editable ? 8 : 12, 8),
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const ConceptHint(_orderNote),
                        if (buttons.isNotEmpty) Wrap(alignment: WrapAlignment.end, spacing: 4, children: buttons),
                      ],
                    )
                  : Row(children: [const Expanded(child: ConceptHint(_orderNote)), ...buttons]),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: ConceptHint(widget.editable
                            ? '단원이 없습니다. "대단원 추가"로 시작하세요.'
                            : '단원이 없습니다. 크게 보기에서 단원을 추가할 수 있습니다.'),
                      ),
                    )
                  : Scrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                        itemCount: rows.length,
                        itemBuilder: (context, i) => _row(d, rows, i, steps, tallies, compact),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _UnitRow extends StatelessWidget {
  const _UnitRow({
    required this.draft,
    required this.row,
    required this.step,
    required this.first,
    required this.last,
    required this.selected,
    this.dropTarget = false,
    required this.editable,
    required this.onTap,
    required this.onToggle,
    required this.onToggleConcepts,
    this.concepts = 0,
    this.conceptsOpen = false,
    this.tally,
    this.compact = false,
  });

  final CourseMapDraft draft;
  final _Row row;
  final (int, int) step;
  final bool first;
  final bool last;
  final bool selected;

  /// 다른 단원으로 끌어 올렸을 때. 놓이면 그 단원 끝이 된다.
  final bool dropTarget;
  final bool editable;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onToggleConcepts;

  /// 이 단원에 바로 놓인 개념 수(아래 단원 것은 빼고).
  final int concepts;
  final bool conceptsOpen;

  /// 대·중단원: 아래 단원까지 합친 수.
  final CourseUnitTally? tally;
  final bool compact;

  Widget _chevron(bool open, VoidCallback onTap, {Key? key}) => InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedRotation(
          turns: open ? 0.25 : 0,
          duration: const Duration(milliseconds: 160),
          child: const Icon(Icons.chevron_right, size: 18, color: kThinkSub),
        ),
      );

  Widget? _tally() {
    final t = tally;
    if (t == null || t.concepts == 0) return null;
    const style = TextStyle(color: kThinkHint, fontSize: 11, fontWeight: FontWeight.w700);
    return Tooltip(
      message: '아래 단원까지 놓인 개념 ${t.concepts}개(같은 개념은 한 번)\n'
          '맨 아래 단원 ${t.leaves}곳 중 ${t.filledLeaves}곳에 개념이 놓임',
      child: Row(
        key: ValueKey('unit-tally-${row.id}'),
        mainAxisSize: MainAxisSize.min,
        children: compact
            ? [
                const Icon(Icons.menu_book_outlined, size: 12, color: kThinkHint),
                const SizedBox(width: 4),
                Text('${t.concepts} · ${t.filledLeaves}/${t.leaves}', style: style),
              ]
            : [Text('개념 ${t.concepts} · 소단원 ${t.filledLeaves}/${t.leaves}', style: style)],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = draft;
    final n = d.node(row.id)!;
    final hasKids = d.childrenOf(row.id).isNotEmpty;
    final open = d.expanded.contains(row.id);
    final tallyView = _tally();
    final (from, to) = step;
    final stepText = hasKids ? (from == to ? '$from' : '$from–$to') : '$from';
    final name = n.name.trim().isEmpty ? '(이름 없음)' : n.name.trim();
    final style = switch (row.depth) {
      1 => const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700),
      2 => const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w600),
      _ => const TextStyle(color: kThinkSub, fontSize: 13, fontWeight: FontWeight.w500),
    };
    final String? mark = n.isNew
        ? '새 단원'
        : d.isMoved(row.id)
            ? '자리 바뀜'
            : d.isRenamed(row.id)
                ? '이름 바뀜'
                : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 56,
          child: CustomPaint(
            painter: _RailPainter(first: first, last: last, leaf: !hasKids),
            child: Padding(
              padding: const EdgeInsets.only(right: 22),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  stepText,
                  style: hasKids
                      ? const TextStyle(color: kThinkHint, fontSize: 11, fontWeight: FontWeight.w600)
                      : const TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('course-unit-${row.id}'),
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: EdgeInsets.only(left: 4 + (row.depth - 1) * 16.0, right: 8),
                  decoration: BoxDecoration(
                    color: (selected || dropTarget) ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (selected || dropTarget) ? kThinkAccent.withValues(alpha: 0.6) : Colors.transparent,
                      width: dropTarget ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        child: hasKids
                            ? _chevron(open, onToggle)
                            : concepts > 0
                                ? Tooltip(
                                    message: conceptsOpen ? '개념 줄 접기' : '놓인 개념 보기',
                                    child: _chevron(conceptsOpen, onToggleConcepts,
                                        key: ValueKey('unit-concepts-toggle-${row.id}')),
                                  )
                                : null,
                      ),
                      Text(d.numberLabel(row.id),
                          style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w800)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
                      if (tallyView != null) ...[
                        const SizedBox(width: 8),
                        tallyView,
                      ],
                      if (concepts > 0) ...[
                        const SizedBox(width: 8),
                        Tooltip(
                          message: '이 단원에 놓인 개념 $concepts개 · 눌러서 ${conceptsOpen ? '접기' : '보기'}',
                          child: InkWell(
                            key: ValueKey('unit-concepts-${row.id}'),
                            onTap: onToggleConcepts,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.menu_book_outlined,
                                      size: 12, color: conceptsOpen ? kThinkAccent : kThinkHint),
                                  const SizedBox(width: 4),
                                  Text('$concepts',
                                      style: TextStyle(
                                          color: conceptsOpen ? kThinkAccent : kThinkHint,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (mark != null) ...[
                        const SizedBox(width: 8),
                        ThinkBadge(mark, color: n.isNew ? kThinkAccent : kThinkLink),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 정의·표현은 단원 바로 아래. 그 밖 유형은 단원 한 단계와 같은 16만큼 더 들여 쓴다. 순서·저장은 바꾸지 않는다.
double _conceptRowInset(int depth, String? type) {
  final name = (type ?? '').trim();
  final extra = (name == '정의' || name == '표현') ? 0.0 : 16.0;
  return 28 + (depth - 1) * 16.0 + extra;
}

/// 단원 아래에 펼친 개념 한 줄. 누르면 옆 칸의 선택한 단원 위에 그 개념을 둔다.
class _ConceptRow extends StatelessWidget {
  const _ConceptRow({
    required this.placement,
    required this.depth,
    required this.last,
    this.selected = false,
    this.onOpen,
    this.onAccept,
    this.onMove,
    this.onRemove,
    this.busy = false,
  });

  final CourseMapPlacement placement;
  final int depth;
  final bool last;
  final bool selected;
  final VoidCallback? onOpen;
  final VoidCallback? onAccept;
  final VoidCallback? onMove;
  final VoidCallback? onRemove;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = placement;
    final type = conceptTypeStyle(p.type);
    final note = p.note;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 56,
          child: CustomPaint(painter: _RailPainter(first: false, last: last, leaf: true, dot: false)),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('outline-concept-${p.id}'),
                onTap: onOpen,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  key: ValueKey('outline-concept-fill-${p.id}'),
                  padding: EdgeInsets.only(left: _conceptRowInset(depth, p.type), right: 8),
                  decoration: BoxDecoration(
                    color: selected ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? kThinkAccent.withValues(alpha: 0.6) : Colors.transparent),
                  ),
                  child: Row(
                    children: [
                      Tooltip(message: type.label, child: ConceptTypeGlyph(type)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          p.name.trim().isEmpty ? '(이름 없음)' : p.name.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (p.byThink) ...[
                        const SizedBox(width: 8),
                        _ThinkPlacementChip(
                          key: ValueKey('outline-think-${p.id}'),
                          label: 'Think',
                          note: note,
                          onAccept: onAccept,
                        ),
                      ],
                      if (onOpen != null) ...[
                        const SizedBox(width: 8),
                        const Tooltip(
                          message: '옆에서 이 개념 보기',
                          child: Icon(Icons.open_in_new, size: 14, color: kThinkHint),
                        ),
                      ],
                      if (onMove != null && onRemove != null)
                        PopupMenuButton<String>(
                          key: ValueKey('outline-concept-menu-${p.id}'),
                          tooltip: '옮기기·빼기',
                          enabled: !busy,
                          padding: EdgeInsets.zero,
                          color: kThinkPanel,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kThinkBorder)),
                          style: IconButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(24, 24),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.more_horiz, size: 18, color: kThinkSub),
                          onSelected: (v) {
                            if (v == 'move') {
                              onMove!();
                            } else {
                              onRemove!();
                            }
                          },
                          itemBuilder: (context) => [
                            _menuItem('move', Icons.drive_file_move_outline, '다른 단원으로 옮기기'),
                            _menuItem('remove', Icons.remove_circle_outline, '이 단원에서 빼기', color: kThinkError),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 왼쪽 세로선과 점. 선은 위아래 줄을 잇는 나열 순서일 뿐이다. 개념 줄은 선만 잇는다.
class _RailPainter extends CustomPainter {
  const _RailPainter({required this.first, required this.last, required this.leaf, this.dot = true});

  final bool first;
  final bool last;
  final bool leaf;
  final bool dot;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width - 10;
    final y = size.height / 2;
    final line = Paint()
      ..color = kThinkBorder
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, first ? y : 0), Offset(x, last ? y : size.height), line);
    if (!dot) return;
    if (leaf) {
      canvas.drawCircle(Offset(x, y), 4, Paint()..color = kThinkAccent);
    } else {
      canvas.drawCircle(Offset(x, y), 4, Paint()..color = kThinkPanel);
      canvas.drawCircle(
        Offset(x, y),
        3.5,
        Paint()
          ..color = kThinkHint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.first != first || old.last != last || old.leaf != leaf || old.dot != dot;
}

class _NameField extends StatefulWidget {
  const _NameField({
    super.key,
    required this.initial,
    required this.label,
    required this.maxLength,
    required this.onChanged,
    this.enabled = true,
  });

  final String initial;
  final String label;
  final int maxLength;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final TextEditingController _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _text,
      enabled: widget.enabled,
      maxLength: widget.maxLength,
      style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700),
      decoration: thinkInputDecoration(label: widget.label, dense: true),
      onChanged: widget.onChanged,
    );
  }
}

class _CurriculumField extends StatelessWidget {
  const _CurriculumField({required this.value, required this.enabled, required this.onChanged});

  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final known = value == null || kCourseMapCurricula.containsKey(value);
    return DropdownButtonFormField<String?>(
      key: ValueKey('course-curriculum-$value'),
      initialValue: value,
      isExpanded: true,
      dropdownColor: kThinkPanel,
      style: const TextStyle(color: kThinkText, fontSize: 14),
      decoration: thinkInputDecoration(label: '교육과정', dense: true),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('미기록')),
        for (final e in kCourseMapCurricula.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
        if (!known) DropdownMenuItem<String?>(value: value, child: Text(value!)),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}

class _ArchivedUnitTile extends StatelessWidget {
  const _ArchivedUnitTile({required this.unit, required this.busy, required this.onRestore, this.blockedReason});

  final CourseMapArchivedUnit unit;
  final bool busy;
  final String? blockedReason;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final where = unit.path.isEmpty ? '맨 위' : unit.path.join(' › ');
    final button = TextButton.icon(
      onPressed: busy || blockedReason != null ? null : onRestore,
      icon: const Icon(Icons.unarchive_outlined, size: 16),
      label: const Text('되살리기'),
      style: TextButton.styleFrom(foregroundColor: kThinkAccent, visualDensity: VisualDensity.compact),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(unit.name, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          ConceptHint('${_levelName(unit.depth)} · $where · 함께 보관 ${unit.count}개 · ${formatDateTime(unit.archivedAt)}'),
          Align(
            alignment: Alignment.centerRight,
            child: blockedReason == null ? button : Tooltip(message: blockedReason!, child: button),
          ),
        ],
      ),
    );
  }
}

class _MoveTarget {
  const _MoveTarget(this.parentId);

  final String? parentId;
}

/// 같은 과정 안에서만 고른다. 자기 아래, 세 단계를 넘는 자리는 막는다.
class _MoveDialog extends StatelessWidget {
  const _MoveDialog({required this.draft, required this.id});

  final CourseMapDraft draft;
  final String id;

  @override
  Widget build(BuildContext context) {
    final d = draft;
    final moving = d.node(id)!;
    final mine = d.subtree(id).toSet();
    final targets = <String?>[null, ...d.flatIds().where((x) => !mine.contains(x))];
    final height = math.min(480.0, MediaQuery.sizeOf(context).height - 240);
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text('"${moving.name.trim()}" 옮기기', style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 520,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ConceptHint('고른 단원의 맨 끝으로 옮깁니다. 같은 과정 안에서만 옮길 수 있고, 아래 단원도 함께 옮겨집니다.'),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: targets.length,
                itemBuilder: (context, i) {
                  final t = targets[i];
                  final why = d.whyCannotReparent(id, t);
                  final current = t == moving.parentId;
                  final depth = t == null ? 0 : d.depthOf(t);
                  final label = t == null ? '맨 위(대단원으로)' : '${d.numberLabel(t)}  ${d.node(t)!.name.trim()}';
                  final row = InkWell(
                    onTap: why == null ? () => Navigator.pop(context, _MoveTarget(t)) : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Opacity(
                      opacity: why == null ? 1 : 0.4,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(8 + depth * 16.0, 8, 8, 8),
                        child: Row(
                          children: [
                            Icon(t == null ? Icons.vertical_align_top : Icons.subdirectory_arrow_right,
                                size: 16, color: kThinkSub),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600)),
                            ),
                            if (current) const ThinkBadge('지금 위치', color: kThinkLink),
                          ],
                        ),
                      ),
                    ),
                  );
                  return why == null ? row : Tooltip(message: why, child: row);
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
      ],
    );
  }
}

class _HoldToDrag extends StatefulWidget {
  const _HoldToDrag({
    super.key,
    required this.enabled,
    required this.onDrop,
    required this.buildChild,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final bool enabled;
  final ValueChanged<Offset> onDrop;
  final Widget Function() buildChild;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragEnd;

  @override
  State<_HoldToDrag> createState() => _HoldToDragState();
}

class _HoldToDragState extends State<_HoldToDrag> {
  final GlobalKey _boxKey = GlobalKey();
  Timer? _hold;
  int? _pointer;
  Offset _down = Offset.zero;
  Offset _point = Offset.zero;
  bool _dragging = false;
  OverlayEntry? _entry;
  Size _size = Size.zero;

  @override
  void dispose() {
    _hold?.cancel();
    _entry?.remove();
    super.dispose();
  }

  void _arm() {
    if (!mounted || _pointer == null) return;
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    setState(() {
      _dragging = true;
      _size = box.size;
    });
    _entry = OverlayEntry(builder: _feedback);
    Overlay.of(context).insert(_entry!);
  }

  Widget _feedback(BuildContext context) {
    return Positioned(
      left: _point.dx - _size.width / 2,
      top: _point.dy - _size.height / 2,
      width: _size.width,
      height: _size.height,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: widget.buildChild(),
        ),
      ),
    );
  }

  void _onDown(PointerDownEvent event) {
    if (!widget.enabled || _dragging) return;
    _pointer = event.pointer;
    _down = event.position;
    _point = event.position;
    _hold?.cancel();
    _hold = Timer(kLongPressTimeout, _arm);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    _point = event.position;
    if (!_dragging) {
      if ((event.position - _down).distance > kTouchSlop) {
        _hold?.cancel();
        _hold = null;
      }
      return;
    }
    _entry?.markNeedsBuild();
    widget.onDragUpdate?.call(event.position);
  }

  void _end(PointerEvent event) {
    if (event.pointer != _pointer) return;
    final dropped = _dragging;
    final at = event.position;
    _hold?.cancel();
    _hold = null;
    _pointer = null;
    _entry?.remove();
    _entry = null;
    if (_dragging && mounted) setState(() => _dragging = false);
    _dragging = false;
    if (dropped) widget.onDrop(at);
    widget.onDragEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      key: _boxKey,
      onPointerDown: _onDown,
      onPointerMove: _move,
      onPointerUp: _end,
      onPointerCancel: _end,
      child: _dragging ? Opacity(opacity: 0.35, child: widget.buildChild()) : widget.buildChild(),
    );
  }
}

/// Think가 놓은 자리. 누르면 확인한 것으로 두고 칩은 걷는다.
class _ThinkPlacementChip extends StatelessWidget {
  const _ThinkPlacementChip({super.key, required this.label, required this.note, this.onAccept});

  final String label;
  final String? note;
  final VoidCallback? onAccept;

  @override
  Widget build(BuildContext context) {
    final tip = StringBuffer(note == null ? 'Think 카드 승인으로 놓였습니다.' : 'Think 근거: $note');
    if (onAccept != null) tip.write('\n눌러 확인');
    final badge = Tooltip(message: tip.toString(), child: ThinkBadge(label, color: kThinkLink));
    if (onAccept == null) return badge;
    return GestureDetector(onTap: onAccept, behavior: HitTestBehavior.opaque, child: badge);
  }
}

/// 개념 이름으로 찾아 여러 개를 고른다. 이미 이 단원에 있는 개념은 막는다.
class _ConceptPickDialog extends StatefulWidget {
  const _ConceptPickDialog({
    required this.controller,
    required this.unitName,
    required this.here,
    required this.elsewhere,
  });

  final CourseMapController controller;
  final String unitName;
  final Set<String> here;

  /// 개념 id → 이 과정에서 놓인 다른 단원 번호.
  final Map<String, List<String>> elsewhere;

  @override
  State<_ConceptPickDialog> createState() => _ConceptPickDialogState();
}

class _ConceptPickDialogState extends State<_ConceptPickDialog> {
  final TextEditingController _query = TextEditingController();
  final Map<String, String> _picked = {};
  Timer? _debounce;
  List<CourseMapConceptHit>? _hits;
  String? _error;
  bool _loading = false;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onQuery(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _search);
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    final seq = ++_seq;
    if (q.isEmpty) {
      setState(() {
        _hits = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final hits = await widget.controller.searchConcepts(q);
      if (!mounted || seq != _seq) return;
      setState(() {
        _hits = hits;
        _error = null;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _hits = null;
        _error = CourseMapException.from(e).message;
      });
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  Widget _results() {
    final error = _error;
    if (error != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: ThinkNotice(text: '찾지 못했습니다: $error', color: kThinkError, icon: Icons.error_outline),
      );
    }
    final hits = _hits;
    if (hits == null) {
      return const Align(alignment: Alignment.topLeft, child: ConceptHint('개념 이름 일부를 입력하면 찾습니다(최대 30개).'));
    }
    if (hits.isEmpty) return const Align(alignment: Alignment.topLeft, child: ConceptHint('맞는 개념이 없습니다.'));
    return ListView.builder(
      itemCount: hits.length,
      itemBuilder: (context, i) {
        final h = hits[i];
        final blocked = widget.here.contains(h.id);
        final picked = _picked.containsKey(h.id);
        final other = widget.elsewhere[h.id];
        return Opacity(
          opacity: blocked ? 0.4 : 1,
          child: InkWell(
            key: ValueKey('concept-pick-${h.id}'),
            onTap: blocked
                ? null
                : () => setState(() => picked ? _picked.remove(h.id) : _picked[h.id] = h.name),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  Icon(picked ? Icons.check_box : Icons.check_box_outline_blank,
                      size: 20, color: picked ? kThinkAccent : kThinkHint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(h.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600)),
                        if (other != null) ConceptHint('이 과정 ${other.join(' · ')} 단원에도 있음'),
                      ],
                    ),
                  ),
                  if (blocked) const ThinkBadge('이미 있음', color: kThinkLink),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = math.min(480.0, MediaQuery.sizeOf(context).height - 240);
    final n = _picked.length;
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text('"${widget.unitName}"에 개념 추가',
          style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 520,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              style: const TextStyle(color: kThinkText, fontSize: 14),
              decoration: thinkInputDecoration(label: '개념 이름', dense: true).copyWith(
                prefixIcon: const Icon(Icons.search_rounded, size: 18, color: kThinkSub),
                suffixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent)),
                      )
                    : null,
              ),
              onChanged: _onQuery,
            ),
            const SizedBox(height: 12),
            Expanded(child: _results()),
            if (n > 0) ...[
              const SizedBox(height: 8),
              ConceptHint('고른 개념: ${_picked.values.join(', ')}'),
            ],
            const SizedBox(height: 8),
            const ConceptHint('단원 맨 끝에 넣습니다. 같은 개념을 다른 단원에도 둘 수 있습니다.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(
          key: const ValueKey('concept-pick-confirm'),
          onPressed: n > 0 ? () => Navigator.pop(context, _picked.keys.toList()) : null,
          style: thinkPrimaryButton(),
          child: Text('넣기 ($n)'),
        ),
      ],
    );
  }
}

/// 놓인 개념을 같은 과정의 다른 저장된 단원으로. 저장 전 새 단원·이미 그 개념이 있는 단원은 막는다.
class _PlacementMoveDialog extends StatelessWidget {
  const _PlacementMoveDialog({required this.draft, required this.placement, required this.taken});

  final CourseMapDraft draft;
  final CourseMapPlacement placement;

  /// 이 개념이 이미 놓인 단원.
  final Set<String> taken;

  @override
  Widget build(BuildContext context) {
    final d = draft;
    final targets = d.flatIds();
    final height = math.min(480.0, MediaQuery.sizeOf(context).height - 240);
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text('"${placement.name.trim()}" 옮기기',
          style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 520,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConceptHint('고른 단원의 맨 끝으로 옮깁니다.${placement.byThink ? ' 옮기면 Think 근거는 지워집니다.' : ''}'),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: targets.length,
                itemBuilder: (context, i) {
                  final t = targets[i];
                  final current = t == placement.unitId;
                  final why = current
                      ? null
                      : d.node(t)!.isNew
                          ? '저장 전 새 단원입니다. 저장한 뒤에 옮길 수 있습니다.'
                          : taken.contains(t)
                              ? '이 개념이 이미 놓인 단원입니다.'
                              : null;
                  final enabled = !current && why == null;
                  final row = InkWell(
                    onTap: enabled ? () => Navigator.pop(context, t) : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Opacity(
                      opacity: enabled || current ? 1 : 0.4,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(8 + (d.depthOf(t) - 1) * 16.0, 8, 8, 8),
                        child: Row(
                          children: [
                            Text(d.numberLabel(t),
                                style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w800)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(d.node(t)!.name.trim(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600)),
                            ),
                            if (current) const ThinkBadge('지금 위치', color: kThinkLink),
                          ],
                        ),
                      ),
                    ),
                  );
                  return why == null ? row : Tooltip(message: why, child: row);
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
      ],
    );
  }
}

Future<void> _createCourse(BuildContext context, CourseMapController c) async {
  final input = await showDialog<_NewCourse>(context: context, builder: (_) => const _CreateCourseDialog());
  if (input == null || !context.mounted) return;
  final problem = await c.createCourse(name: input.name, schoolLevel: input.level, curriculumCode: input.code);
  if (!context.mounted) return;
  showThinkSnack(context, problem ?? '"${input.name}" 과정을 만들었습니다.', error: problem != null);
}

class _NewCourse {
  const _NewCourse(this.name, this.level, this.code);

  final String name;
  final String level;
  final String? code;
}

class _CreateCourseDialog extends StatefulWidget {
  const _CreateCourseDialog();

  @override
  State<_CreateCourseDialog> createState() => _CreateCourseDialogState();
}

class _CreateCourseDialogState extends State<_CreateCourseDialog> {
  final TextEditingController _name = TextEditingController();
  String _level = '고';
  String? _code = 'rev_2022';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _name.text.trim();
    final ok = name.isNotEmpty && name.length <= kCourseMapCourseNameMax;
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('과정 추가', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: kCourseMapCourseNameMax,
              style: const TextStyle(color: kThinkText),
              decoration: thinkInputDecoration(label: '과정 이름', hint: '예: 중등 심화'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final level in kCourseMapSchoolLevels)
                  ThinkToggleChip(
                    label: level,
                    icon: Icons.school_outlined,
                    selected: _level == level,
                    onChanged: (_) => setState(() => _level = level),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _CurriculumField(value: _code, enabled: true, onChanged: (v) => setState(() => _code = v)),
            const SizedBox(height: 8),
            const ConceptHint('새 과정은 목록 맨 끝에 들어가고, 단원 없이 시작합니다.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(
          onPressed: ok ? () => Navigator.pop(context, _NewCourse(name, _level, _code)) : null,
          style: thinkPrimaryButton(),
          child: const Text('만들기'),
        ),
      ],
    );
  }
}

Future<void> _showArchivedCourses(BuildContext context, CourseMapController c) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        final list = c.archivedCourses;
        return AlertDialog(
          backgroundColor: kThinkBg,
          shape: thinkDialogShape,
          title: const Text('보관한 과정', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: 460,
            child: list.isEmpty
                ? const ConceptHint('보관한 과정이 없습니다.')
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(color: kThinkBorder, height: 16),
                    itemBuilder: (ctx, i) {
                      final x = list[i];
                      return Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(x.name,
                                    style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 4),
                                ConceptHint('대 ${x.counts[0]} · 중 ${x.counts[1]} · 소 ${x.counts[2]} · '
                                    '${formatDateTime(x.archivedAt)} 보관'),
                              ],
                            ),
                          ),
                          TextButton.icon(
                            onPressed: c.busy
                                ? null
                                : () async {
                                    final problem = await c.restoreCourse(x.id);
                                    if (!ctx.mounted) return;
                                    if (problem != null) {
                                      showThinkSnack(ctx, problem, error: true);
                                    } else {
                                      Navigator.pop(ctx);
                                    }
                                  },
                            icon: const Icon(Icons.unarchive_outlined, size: 16),
                            label: const Text('되살리기'),
                            style: TextButton.styleFrom(foregroundColor: kThinkAccent),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('닫기', style: TextStyle(color: kThinkSub)),
            ),
          ],
        );
      },
    ),
  );
}
