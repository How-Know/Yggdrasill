import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/course_map_controller.dart';
import '../../../services/course_map_service.dart';
import '../../think/think_style.dart';
import 'concept_type_chip.dart';
import 'concept_workspace.dart';
import 'course_change_log_dialog.dart';

/// 기준 과정 탐색도(`docs/architecture/course-map.md`). 개념 탭 왼쪽 칸과 문항로드맵 메뉴가 같은 컨트롤러를 쓴다.
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

Widget _changeLogButton(BuildContext context, CourseMapController c, ValueChanged<String>? onOpenConcept) => IconButton(
      key: const ValueKey('course-change-log'),
      tooltip: '최근 변경 기록',
      onPressed: () => unawaited(showCourseChangeLog(context, controller: c, onOpenConcept: onOpenConcept)),
      icon: const Icon(Icons.history, size: 18),
      color: kThinkSub,
    );

/// 크게 볼 때(편집).
class CourseMapPane extends StatefulWidget {
  const CourseMapPane({super.key, required this.controller, this.onOpenConcept});

  final CourseMapController controller;

  /// 흐름 목록의 개념 줄을 누르면 부른다. 없으면 개념 줄은 보기만 한다.
  final ValueChanged<String>? onOpenConcept;

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
    return ListenableBuilder(
      listenable: _c,
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
                  _changeLogButton(context, _c, widget.onOpenConcept),
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
        _CourseStrip(controller: _c, withMenu: true),
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
              final outline =
                  _CourseOutline(controller: _c, draft: d, editable: true, onOpenConcept: widget.onOpenConcept);
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
        controller: _sideScroll,
        padding: const EdgeInsets.all(16),
        children: [
          if (id != null && d.node(id) != null) ...[
            ..._unitEditor(d, id),
            const SizedBox(height: 16),
            const Divider(color: kThinkBorder, height: 1),
            const SizedBox(height: 12),
            ..._unitConcepts(d, id),
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
            label: Text('뒤에 ${_levelName(depth)} 추가'),
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
      const SizedBox(height: 8),
      const ConceptHint('위로·아래로는 같은 단원 안 순서만 바꿉니다. 다른 단원 아래로는 "옮기기"를 쓰세요.'),
    ];
  }

  List<Widget> _unitConcepts(CourseMapDraft d, String unitId) {
    final courseId = d.course.id;
    final n = d.node(unitId)!;
    final error = _c.placementError(courseId);
    final loaded = _c.placementsOf(courseId) != null;
    final here = _c.placementsIn(courseId, unitId);
    final busy = _locked || _c.placementBusyCourseId != null;
    return [
      ConceptSectionTitle(
        loaded && !n.isNew ? '이 단원의 개념 (${here.length})' : '이 단원의 개념',
        trailing: !loaded || n.isNew
            ? null
            : TextButton.icon(
                key: const ValueKey('placement-add'),
                onPressed: busy ? null : () => _addConcepts(d, unitId),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('개념 넣기'),
                style: TextButton.styleFrom(foregroundColor: kThinkAccent, visualDensity: VisualDensity.compact),
              ),
      ),
      if (n.isNew)
        const ConceptHint('저장 전 새 단원입니다. 저장한 뒤에 개념을 넣을 수 있습니다.')
      else if (error != null) ...[
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
      ] else if (!loaded)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(color: kThinkAccent, backgroundColor: kThinkBorder, minHeight: 2),
        )
      else if (here.isEmpty)
        const ConceptHint('아직 놓인 개념이 없습니다. "개념 넣기"로 넣거나, Think 대화에서 배치를 부탁하면 카드로 제안합니다.')
      else
        for (var i = 0; i < here.length; i++) ...[
          _PlacementTile(
            placement: here[i],
            busy: busy,
            canUp: i > 0,
            canDown: i < here.length - 1,
            onShift: (delta) => _shiftPlacement(unitId, here[i], delta),
            onMove: () => _movePlacement(d, here[i]),
            onRemove: () => _removePlacement(here[i]),
          ),
          if (i < here.length - 1) const SizedBox(height: 8),
        ],
      if (loaded && !n.isNew) ...[
        const SizedBox(height: 8),
        const ConceptHint('넣기·빼기·순서·옮기기는 바로 저장됩니다(아래 "저장"과 따로). 개념 본문·출처는 바뀌지 않습니다.'),
      ],
    ];
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

  Future<void> _shiftPlacement(String unitId, CourseMapPlacement p, int delta) async {
    final problem = await _c.shiftPlacement(unitId, p.id, delta);
    if (problem != null && mounted) showThinkSnack(context, problem, error: true);
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
    showThinkSnack(context, problem ?? '"${p.name}"을(를) ${d.numberLabel(target)} 단원으로 옮겼습니다.',
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
  const CourseMapSummaryPane({super.key, required this.controller, this.onExpand, this.onOpenConcept});

  final CourseMapController controller;
  final VoidCallback? onExpand;
  final ValueChanged<String>? onOpenConcept;

  @override
  State<CourseMapSummaryPane> createState() => _CourseMapSummaryPaneState();
}

class _CourseMapSummaryPaneState extends State<CourseMapSummaryPane> {
  CourseMapController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _startLoading(_c);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => ThinkPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConceptPaneHeader(
              icon: Icons.timeline,
              title: '교육과정 흐름',
              badges: [_draftBadge()],
              actions: [_changeLogButton(context, _c, widget.onOpenConcept)],
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
                  : _CourseOutline(controller: _c, draft: d, editable: false, onOpenConcept: widget.onOpenConcept),
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
  const _CourseStrip({required this.controller, required this.withMenu});

  final CourseMapController controller;
  final bool withMenu;

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
  const _CourseOutline({required this.controller, required this.draft, required this.editable, this.onOpenConcept});

  final CourseMapController controller;
  final CourseMapDraft draft;
  final bool editable;
  final ValueChanged<String>? onOpenConcept;

  @override
  State<_CourseOutline> createState() => _CourseOutlineState();
}

class _CourseOutlineState extends State<_CourseOutline> {
  final ScrollController _scroll = ScrollController();

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

  Widget _row(CourseMapDraft d, List<_Row> rows, int i, Map<String, (int, int)> steps,
      Map<String, CourseUnitTally> tallies, bool compact) {
    final c = widget.controller;
    final courseId = d.course.id;
    final r = rows[i];
    final last = i == rows.length - 1;
    final p = r.placement;
    final open = widget.onOpenConcept;
    if (p != null) {
      return _ConceptRow(
        placement: p,
        depth: r.depth,
        last: last,
        onOpen: open == null ? null : () => open(p.conceptId),
      );
    }
    final hasKids = d.childrenOf(r.id).isNotEmpty;
    final concepts = c.placementCount(courseId, r.id);
    return _UnitRow(
      draft: d,
      row: r,
      step: steps[r.id] ?? (0, 0),
      first: i == 0,
      last: last,
      selected: r.id == d.selectedId,
      editable: widget.editable,
      concepts: concepts,
      conceptsOpen: c.conceptsOpen(courseId, r.id),
      tally: hasKids ? tallies[r.id] : null,
      compact: compact,
      onTap: () {
        c.selectUnit(r.id);
        if (!widget.editable && !hasKids && concepts > 0) c.toggleConcepts(courseId, r.id);
      },
      onToggle: () => c.toggleExpanded(r.id),
      onToggleConcepts: () => c.toggleConcepts(courseId, r.id),
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
                        itemExtentBuilder: (i, _) =>
                            i < 0 || i >= rows.length ? null : (rows[i].placement == null ? 36 : 32),
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
                    color: selected ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: selected ? kThinkAccent.withValues(alpha: 0.6) : Colors.transparent),
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

/// 단원 아래에 펼친 개념 한 줄. 누르면 라이브러리에서 연다.
class _ConceptRow extends StatelessWidget {
  const _ConceptRow({required this.placement, required this.depth, required this.last, this.onOpen});

  final CourseMapPlacement placement;
  final int depth;
  final bool last;
  final VoidCallback? onOpen;

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
                child: Padding(
                  padding: EdgeInsets.only(left: 28 + (depth - 1) * 16.0, right: 8),
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
                        Tooltip(
                          message: note == null ? 'Think 카드 승인으로 놓였습니다.' : 'Think 근거: $note',
                          child: const ThinkBadge('Think', color: kThinkLink),
                        ),
                      ],
                      if (onOpen != null) ...[
                        const SizedBox(width: 8),
                        const Tooltip(
                          message: '라이브러리에서 열기',
                          child: Icon(Icons.open_in_new, size: 14, color: kThinkHint),
                        ),
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

/// 단원에 놓인 개념 한 줄: 유형 글자 + 이름 + (Think가 놓았으면 근거 배지) + 위·아래·더보기.
class _PlacementTile extends StatelessWidget {
  const _PlacementTile({
    required this.placement,
    required this.busy,
    required this.canUp,
    required this.canDown,
    required this.onShift,
    required this.onMove,
    required this.onRemove,
  });

  final CourseMapPlacement placement;
  final bool busy;
  final bool canUp;
  final bool canDown;
  final ValueChanged<int> onShift;
  final VoidCallback onMove;
  final VoidCallback onRemove;

  Widget _icon(IconData icon, String tooltip, VoidCallback? onPressed) => IconButton(
        tooltip: tooltip,
        onPressed: busy ? null : onPressed,
        icon: Icon(icon, size: 16),
        color: kThinkSub,
        disabledColor: kThinkBorder,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
      );

  @override
  Widget build(BuildContext context) {
    final p = placement;
    final type = conceptTypeStyle(p.type);
    final note = p.note;
    return Container(
      key: ValueKey('placement-${p.id}'),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: kThinkBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Row(
        children: [
          Tooltip(message: type.label, child: ConceptTypeGlyph(type)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(p.name.trim().isEmpty ? '(이름 없음)' : p.name.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (p.byThink)
                      Tooltip(
                        message: note == null ? 'Think 카드 승인으로 놓였습니다.' : 'Think 근거: $note',
                        child: const ThinkBadge('Think 배치', color: kThinkLink),
                      ),
                    Text('출처 ${p.sources}개', style: const TextStyle(color: kThinkHint, fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),
          _icon(Icons.arrow_upward, '위로', canUp ? () => onShift(-1) : null),
          _icon(Icons.arrow_downward, '아래로', canDown ? () => onShift(1) : null),
          PopupMenuButton<String>(
            tooltip: '더보기',
            enabled: !busy,
            color: kThinkPanel,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kThinkBorder)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 180),
            icon: const Icon(Icons.more_horiz, size: 18, color: kThinkSub),
            onSelected: (v) {
              if (v == 'move') {
                onMove();
              } else {
                onRemove();
              }
            },
            itemBuilder: (context) => [
              _menuItem('move', Icons.drive_file_move_outline, '다른 단원으로 옮기기'),
              _menuItem('remove', Icons.remove_circle_outline, '이 단원에서 빼기', color: kThinkError),
            ],
          ),
        ],
      ),
    );
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
      title: Text('"${widget.unitName}"에 개념 넣기',
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
