import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import 'package:mneme_flutter/services/past_exam_shortcut_store.dart';
import 'package:mneme_flutter/services/tenant_service.dart';
import 'package:mneme_flutter/utils/naesin_exam_context.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

/// 시험기간 FAB 「기출」: 연도×학교 그리드와 로컬 파일 바로가기.
class PastExamPapersDialog extends StatefulWidget {
  const PastExamPapersDialog({super.key});

  @override
  State<PastExamPapersDialog> createState() => _PastExamPapersDialogState();
}

class _PastExamPapersDialogState extends State<PastExamPapersDialog> {
  static const Color _bg = Color(0xFF121212);
  static const Color _cellEmpty = Color(0xFF2d2d2d);
  static const Color _cellLinked = Color(0xFF39d353);
  static const double _cellRadius = 4;
  /// 그리드 한 칸(패딩 제외 순수 셀)
  static const double _cellSize = 52;
  static const double _cellPad = 5;
  static const double _yearColWidth = 56;
  static const double _headerRowHeight = 56;

  final GlobalKey _gridLayoutKey = GlobalKey();

  String _academyId = '';
  String _gradeKey = 'M1';
  String _courseKey = 'M1-1';
  String _examTerm = '';
  Map<String, String> _pathsByLinkKey = <String, String>{};
  bool _loading = true;
  String? _dragHoverCellId;
  double _gradeWheelAccum = 0;

  List<NaesinGradeOption> get _allGradeOptions => <NaesinGradeOption>[
        ...NaesinExamContext.gradeOptionsForLevel(EducationLevel.middle),
        ...NaesinExamContext.gradeOptionsForLevel(EducationLevel.high),
      ];

  List<String> get _schools => NaesinExamContext.schoolsForGradeKey(_gradeKey);

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _examTerm = NaesinExamContext.defaultNaesinExamTermByDate(now);
    unawaited(_bootstrap());
  }

  Offset _dropLocalInGridContent(Offset globalPosition) {
    final ctx = _gridLayoutKey.currentContext;
    if (ctx == null) return Offset.zero;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    return box.globalToLocal(globalPosition);
  }

  Future<void> _bootstrap() async {
    var academyId =
        (await TenantService.instance.getActiveAcademyId() ?? '').trim();
    if (academyId.isEmpty) {
      academyId = (await TenantService.instance.ensureActiveAcademy()).trim();
    }
    final saved = await PastExamShortcutStore.instance.loadLastGradeCourse();
    final students = DataManager.instance.students;
    final derived = NaesinExamContext.initialGradeCourseFromStudent(
      students.isNotEmpty ? students.first.student : null,
      DateTime.now(),
    );
    var gradeKey = saved.gradeKey ?? derived.gradeKey;
    var courseKey = saved.courseKey ?? derived.courseKey;
    final gradeOk = _allGradeOptions.any((e) => e.key == gradeKey);
    if (!gradeOk) {
      gradeKey = derived.gradeKey;
      courseKey = derived.courseKey;
    }
    final courseOpts = NaesinExamContext.courseOptionsForGrade(gradeKey);
    if (!courseOpts.any((e) => e.key == courseKey)) {
      courseKey = courseOpts.first.key;
    }
    final map = await PastExamShortcutStore.instance.loadAll(academyId);
    if (!mounted) return;
    setState(() {
      _academyId = academyId;
      _gradeKey = gradeKey;
      _courseKey = courseKey;
      _pathsByLinkKey = map;
      _loading = false;
    });
  }

  Future<void> _persistGradeCourse() async {
    await PastExamShortcutStore.instance.saveLastGradeCourse(
      gradeKey: _gradeKey,
      courseKey: _courseKey,
    );
  }

  void _syncCourseWithGrade() {
    final options = NaesinExamContext.courseOptionsForGrade(_gradeKey);
    if (options.any((e) => e.key == _courseKey)) return;
    setState(() => _courseKey = options.first.key);
  }

  String _linkKey(String school, int year) {
    return NaesinExamContext.buildNaesinLinkKey(
      gradeKey: _gradeKey,
      courseKey: _courseKey,
      examTerm: _examTerm,
      school: school,
      year: year,
    );
  }

  bool _allowedFilePath(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.pdf' ||
        ext == '.hwp' ||
        ext == '.hwpx' ||
        ext == '.doc' ||
        ext == '.docx';
  }

  Future<void> _onDropOnCell(
    String school,
    int year,
    DropDoneDetails detail,
  ) async {
    if (_academyId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('학원 정보를 불러올 수 없어 저장할 수 없습니다.')),
        );
      }
      return;
    }
    if (detail.files.isEmpty) return;
    final xf = detail.files.first;
    final path = xf.path.trim();
    if (path.isEmpty) return;
    if (!_allowedFilePath(path)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF, HWP, HWPX, Word 파일만 연결할 수 있어요.')),
        );
      }
      return;
    }
    if (!File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('파일을 찾을 수 없습니다.')),
        );
      }
      return;
    }
    final key = _linkKey(school, year);
    await PastExamShortcutStore.instance.setPath(
      academyId: _academyId,
      linkKey: key,
      filePath: path,
    );
    if (!mounted) return;
    setState(() => _pathsByLinkKey[key] = path);
  }

  /// 단일 [DropTarget]용: 그리드 로컬 좌표 → (school, year).
  void _handleGridDropAtLocal(Offset local, DropDoneDetails detail) {
    const years = NaesinExamContext.linkYears;
    final schools = _schools;
    if (local.dx < _yearColWidth || local.dy < _headerRowHeight) return;
    final relX = local.dx - _yearColWidth;
    final relY = local.dy - _headerRowHeight;
    const stride = _cellSize + _cellPad * 2;
    final col = (relX / stride).floor();
    final row = (relY / stride).floor();
    if (col < 0 || col >= schools.length || row < 0 || row >= years.length) {
      return;
    }
    unawaited(_onDropOnCell(schools[col], years[row], detail));
  }

  void _handleGridPointerMove(Offset globalPosition) {
    const years = NaesinExamContext.linkYears;
    final schools = _schools;
    final local = _dropLocalInGridContent(globalPosition);
    if (local.dx < _yearColWidth || local.dy < _headerRowHeight) {
      if (_dragHoverCellId != null) setState(() => _dragHoverCellId = null);
      return;
    }
    final relX = local.dx - _yearColWidth;
    final relY = local.dy - _headerRowHeight;
    const stride = _cellSize + _cellPad * 2;
    final col = (relX / stride).floor();
    final row = (relY / stride).floor();
    if (col < 0 || col >= schools.length || row < 0 || row >= years.length) {
      if (_dragHoverCellId != null) setState(() => _dragHoverCellId = null);
      return;
    }
    final id = '${schools[col]}|$row';
    if (_dragHoverCellId != id) setState(() => _dragHoverCellId = id);
  }

  Future<void> _openCell(String school, int year) async {
    final key = _linkKey(school, year);
    final path = _pathsByLinkKey[key];
    if (path == null || path.isEmpty) return;
    if (!File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('파일이 이동되었거나 없습니다. 다시 연결해 주세요.')),
        );
      }
      return;
    }
    await OpenFilex.open(path);
  }

  Future<void> _clearCell(String school, int year) async {
    final key = _linkKey(school, year);
    await PastExamShortcutStore.instance.remove(
      academyId: _academyId,
      linkKey: key,
    );
    if (!mounted) return;
    setState(() => _pathsByLinkKey.remove(key));
  }

  Future<void> _pickGrade(String? v) async {
    if (v == null) return;
    setState(() => _gradeKey = v);
    _syncCourseWithGrade();
    await _persistGradeCourse();
  }

  Future<void> _pickCourse(String? v) async {
    if (v == null) return;
    setState(() => _courseKey = v);
    await _persistGradeCourse();
  }

  void _cycleGradeFromWheel(double scrollDeltaDy) {
    _gradeWheelAccum += scrollDeltaDy;
    const threshold = 100;
    if (_gradeWheelAccum.abs() < threshold) return;
    final sign = _gradeWheelAccum.sign;
    _gradeWheelAccum = 0;
    final list = _allGradeOptions;
    final i = list.indexWhere((e) => e.key == _gradeKey);
    if (i < 0) return;
    // 아래로 스크롤(dy>0) → 다음 학년
    final next = sign > 0 ? i + 1 : i - 1;
    if (next < 0 || next >= list.length) return;
    unawaited(_pickGrade(list[next].key));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _bg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFF9FB3B3)),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerSignal: (PointerSignalEvent e) {
                        if (e is! PointerScrollEvent) return;
                        _cycleGradeFromWheel(e.scrollDelta.dy);
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Text(
                                '기출',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close,
                                    color: Colors.white70),
                                tooltip: '닫기',
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '적용 시험 구간: $_examTerm (오늘 날짜 기준, 과제 내신 기출과 동일)',
                            style: const TextStyle(
                              color: Color(0xFF9FB3B3),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _labeledDropdown(
                                label: '학년',
                                value: _gradeKey,
                                items: _allGradeOptions
                                    .map(
                                      (e) => DropdownMenuItem<String>(
                                        value: e.key,
                                        child: Text(e.label),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) => unawaited(_pickGrade(v)),
                              ),
                              if (_gradeKey != 'H3')
                                _labeledDropdown(
                                  label: _gradeKey == 'H2'
                                      ? '과목'
                                      : (_gradeKey.startsWith('H')
                                          ? '과목'
                                          : '과목·분기'),
                                  value: _courseKey,
                                  items: NaesinExamContext.courseOptionsForGrade(
                                          _gradeKey)
                                      .map(
                                        (e) => DropdownMenuItem<String>(
                                          value: e.key,
                                          child: Text(e.label),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) => unawaited(_pickCourse(v)),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '행: 연도 · 열: 학교 · 셀에 파일을 놓으면 바로가기 저장 · 길게 눌러 연결 해제',
                      style: TextStyle(color: Color(0xFF6d7a7a), fontSize: 11),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Listener(
                        behavior: HitTestBehavior.deferToChild,
                        onPointerSignal: (PointerSignalEvent e) {
                          if (e is! PointerScrollEvent) return;
                          _cycleGradeFromWheel(e.scrollDelta.dy);
                        },
                        child: _gradeKey == 'H3'
                            ? const Center(
                                child: Text(
                                  '고3은 이 그리드에 해당하는 시험지 정리가 없습니다.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Color(0xFF9FB3B3),
                                    fontSize: 15,
                                  ),
                                ),
                              )
                            : _buildGridDropArea(),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _labeledDropdown({
    required String label,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required void Function(String?) onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(color: Color(0xFF9FB3B3), fontSize: 13),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1e1e1e),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              dropdownColor: const Color(0xFF2a2a2a),
              style: const TextStyle(color: Colors.white, fontSize: 14),
              items: items,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGridDropArea() {
    return DropTarget(
      onDragUpdated: (d) => _handleGridPointerMove(d.globalPosition),
      onDragEntered: (d) => _handleGridPointerMove(d.globalPosition),
      onDragExited: (_) {
        if (_dragHoverCellId != null) setState(() => _dragHoverCellId = null);
      },
      onDragDone: (detail) {
        setState(() => _dragHoverCellId = null);
        final local = _dropLocalInGridContent(detail.globalPosition);
        _handleGridDropAtLocal(local, detail);
      },
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: KeyedSubtree(
            key: _gridLayoutKey,
            child: _buildGridTable(),
          ),
        ),
      ),
    );
  }

  Widget _buildGridTable() {
    const years = NaesinExamContext.linkYears;
    final schools = _schools;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: _yearColWidth,
              height: _headerRowHeight,
            ),
            for (final school in schools)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: _cellPad),
                child: SizedBox(
                  width: _cellSize,
                  height: _headerRowHeight,
                  child: Center(
                    child: Text(
                      school,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF9FB3B3),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        for (var row = 0; row < years.length; row++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: _yearColWidth,
                height: _cellSize + _cellPad * 2,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '${years[row] % 100}년',
                      style: const TextStyle(
                        color: Color(0xFF9FB3B3),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              for (var col = 0; col < schools.length; col++)
                Padding(
                  padding: const EdgeInsets.all(_cellPad),
                  child: _buildCell(schools[col], years[row], row),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildCell(String school, int year, int row) {
    final key = _linkKey(school, year);
    final hasPath = (_pathsByLinkKey[key] ?? '').isNotEmpty;
    final id = '$school|$row';
    final hovered = _dragHoverCellId == id;
    final bg = hasPath
        ? _cellLinked.withValues(alpha: hovered ? 1.0 : 0.88)
        : _cellEmpty.withValues(alpha: hovered ? 0.92 : 1.0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_openCell(school, year)),
        onLongPress: hasPath
            ? () async {
                await _clearCell(school, year);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('연결을 지웠습니다.')),
                );
              }
            : null,
        child: Container(
          width: _cellSize,
          height: _cellSize,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(_cellRadius),
            border: Border.all(
              color: hovered ? Colors.white30 : Colors.transparent,
              width: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
