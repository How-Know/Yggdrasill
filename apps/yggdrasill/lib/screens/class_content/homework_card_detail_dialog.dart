import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/homework_assignment_store.dart';
import '../../services/homework_store.dart';
import '../../services/homework_time_defaults_service.dart';
import '../../utils/homework_card_label.dart';
import '../../utils/homework_page_text.dart';
import '../../widgets/bottom_dialog.dart';
import '../../widgets/dialog_tokens.dart';
import '../../widgets/latex_text_renderer.dart';
import 'homework_created_date.dart';

/// 홈 과제 카드를 누르면 펼치지 않고 이 창을 연다.
Future<void> showHomeworkCardDetailDialog({
  required BuildContext context,
  required String studentId,
  required HomeworkItem summary,
  required List<HomeworkItem> children,
  required int homeworkCount,
  required bool isHomework,
  String? dueLabel,
  bool showAdditionalPrefix = false,
  void Function(HomeworkItem child)? onChildPageTap,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(
      alpha: BottomDialogMetrics.barrierOpacity,
    ),
    builder: (dialogContext) {
      return HomeworkCardDetailDialog(
        studentId: studentId,
        summary: summary,
        children: children,
        homeworkCount: homeworkCount,
        isHomework: isHomework,
        dueLabel: dueLabel,
        showAdditionalPrefix: showAdditionalPrefix,
        onChildPageTap: onChildPageTap,
      );
    },
  );
}

class HomeworkCardDetailDialog extends StatefulWidget {
  const HomeworkCardDetailDialog({
    super.key,
    required this.studentId,
    required this.summary,
    required this.children,
    required this.homeworkCount,
    required this.isHomework,
    this.dueLabel,
    this.showAdditionalPrefix = false,
    this.onChildPageTap,
  });

  final String studentId;
  final HomeworkItem summary;
  final List<HomeworkItem> children;
  final int homeworkCount;
  final bool isHomework;
  final String? dueLabel;
  final bool showAdditionalPrefix;
  final void Function(HomeworkItem child)? onChildPageTap;

  @override
  State<HomeworkCardDetailDialog> createState() =>
      _HomeworkCardDetailDialogState();
}

class _HomeworkCardDetailDialogState extends State<HomeworkCardDetailDialog> {
  List<HomeworkAssignmentBrief> _history = const [];
  bool _historyLoading = true;
  String? _historyError;
  String _roundLabel = '';
  bool _historyOpen = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadRounds();
  }

  Future<void> _loadHistory() async {
    try {
      final byItem = await HomeworkAssignmentStore.instance
          .loadAssignmentsForStudent(widget.studentId);
      if (!mounted) return;
      final ids = widget.children.map((child) => child.id.trim()).toSet();
      final byAssignmentId = <String, HomeworkAssignmentBrief>{};
      for (final itemId in ids) {
        for (final brief in byItem[itemId] ?? const <HomeworkAssignmentBrief>[]) {
          final id = brief.id.trim();
          if (id.isEmpty) continue;
          byAssignmentId.putIfAbsent(id, () => brief);
        }
      }
      final history = byAssignmentId.values.toList(growable: false)
        ..sort((a, b) => b.assignedAt.compareTo(a.assignedAt));
      setState(() {
        _history = history;
        _historyLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _historyLoading = false;
        _historyError = '숙제 이력을 불러오지 못했습니다.';
      });
    }
  }

  Future<void> _loadRounds() async {
    final crops = <String>{};
    for (final item in widget.children) {
      for (final raw in item.unitMappings ?? const <Map<String, dynamic>>[]) {
        final list = raw['problemCrops'];
        if (list is! List) continue;
        for (final crop in list) {
          if (crop is! Map) continue;
          final id = '${crop['cropId'] ?? ''}'.trim();
          if (id.isNotEmpty) crops.add(id);
        }
      }
    }
    if (widget.studentId.isEmpty || crops.isEmpty) return;
    try {
      final sorted = crops.toList(growable: false)..sort();
      final result = await Supabase.instance.client.rpc(
        'staff_list_problem_rounds_v1',
        params: {
          'p_student_id': widget.studentId,
          'p_crop_ids': sorted,
        },
      );
      if (!mounted) return;
      final rows = result is List ? result : const <dynamic>[];
      final byCrop = <String, int>{};
      var skipped = 0;
      for (final row in rows.whereType<Map>()) {
        final cropId = '${row['crop_id'] ?? ''}'.trim();
        final roundNo = (row['round_no'] as num?)?.toInt() ?? 0;
        if (cropId.isNotEmpty && roundNo > 0) byCrop[cropId] = roundNo;
        final passed = row['passed'] == true;
        final lastResult = '${row['last_result'] ?? ''}'.trim();
        if (cropId.isNotEmpty && !passed && lastResult == 'skipped') {
          skipped += 1;
        }
      }
      var lo = 0;
      var hi = 0;
      for (final cropId in crops) {
        final n = byCrop[cropId] ?? 1;
        if (lo == 0 || n < lo) lo = n;
        if (n > hi) hi = n;
      }
      var label = hi == 0 ? '' : (lo == hi ? '$hi회차' : '$lo~$hi회차');
      if (label.isNotEmpty && skipped > 0) {
        label = '$label · 미수행 $skipped';
      }
      if (label.isEmpty) return;
      setState(() => _roundLabel = label);
    } catch (_) {
      // 회차는 부가 정보. 실패해도 나머지 창은 보여 준다.
    }
  }

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    final summary = widget.summary;
    final children = widget.children;
    final rawTitle = summary.title.trim().isEmpty ? '과제' : summary.title.trim();
    final title = widget.showAdditionalPrefix ? '+ $rawTitle' : rawTitle;
    final bookLine = homeworkCardFirstLine(summary);
    final page = homeworkGroupPageSummary(
      children.map(
        (child) => (page: child.page, unitMappings: child.unitMappings),
      ),
    );
    final count = children.fold<int>(
      0,
      (sum, child) =>
          sum +
          homeworkItemProblemCount(
            count: child.count,
            unitMappings: child.unitMappings,
          ),
    );
    final created = homeworkCreatedDateLabel(_earliestCreated(children));
    final meta = <String>[
      if (created != '-') '내준 $created',
      'p.${page.isEmpty ? '-' : page}',
      '${count > 0 ? count : '-'}문항',
    ].join(' · ');

    return BottomDialog(
      center: true,
      preferredWidth: 1080,
      maxHeight: 900,
      icon: Icons.assignment_outlined,
      title: title,
      onClose: () => Navigator.of(context).pop(),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                children: [
                  Text(
                    bookLine,
                    style: TextStyle(
                      color: dlg.text,
                      fontSize: BottomDialogMetrics.largeFontSize,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    style: TextStyle(
                      color: dlg.textSub,
                      fontSize: BottomDialogMetrics.mediumFontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _listLabel(dlg, '진행'),
                      _fact(dlg, '시작', _clock(summary.firstStartedAt)),
                      _fact(dlg, '이번', _elapsedLabel(summary, children)),
                      _fact(dlg, '총 시간', _minutesLabel(_totalMinutes(summary))),
                      _fact(dlg, '권장', () {
                        final minutes = _groupRecommendedMinutes(children);
                        return minutes <= 0 ? '-' : _minutesLabel(minutes);
                      }()),
                      _fact(dlg, '제한시간', _limitLabel(children)),
                      _fact(dlg, '검사', '${summary.checkCount}회'),
                      _fact(dlg, '숙제', '${math.max(0, widget.homeworkCount)}회'),
                      if (widget.isHomework)
                        _fact(
                          dlg,
                          '검사 날짜',
                          (widget.dueLabel ?? '').trim().isEmpty
                              ? '미정'
                              : widget.dueLabel!.trim(),
                        ),
                      _fact(dlg, '제출 시각', _clock(summary.submittedAt)),
                      _fact(dlg, '확인 시각', _clock(summary.confirmedAt)),
                      _fact(dlg, '대기 시각', _clock(summary.waitingAt)),
                      if (_roundLabel.isNotEmpty)
                        _fact(dlg, '문항 회차', _roundLabel),
                      const SizedBox(height: 8),
                      _section(
                        dlg,
                        title: _historyLoading
                            ? '숙제 이력'
                            : '숙제 이력 ${_history.length}건',
                        open: _historyOpen,
                        onTap: () =>
                            setState(() => _historyOpen = !_historyOpen),
                        children: [_historyBody(dlg)],
                      ),
                    ],
                  ),
                ),
                VerticalDivider(width: 16, thickness: 1, color: dlg.divider),
                Expanded(
                  child: ListView(
                    children: [
                      _listLabel(dlg, '하위과제 ${children.length}개', padTop: false),
                      if (children.isEmpty)
                        _emptyLine(dlg, '하위과제가 없습니다.')
                      else
                        for (var i = 0; i < children.length; i++)
                          _childCard(dlg, children[i], i),
                    ],
                  ),
                ),
              ],
            ),
          ),
    );
  }

  Widget _section(
    YggDialogColors dlg, {
    required String title,
    required bool open,
    required VoidCallback onTap,
    required List<Widget> children,
  }) {
    final radius = BorderRadius.circular(BottomDialogMetrics.cardRadius);
    return Padding(
      padding: const EdgeInsets.only(bottom: BottomDialogMetrics.actionGap),
      child: Material(
        color: dlg.cardBg,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: dlg.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: BottomDialogMetrics.cardHorizontalPadding,
                  vertical: BottomDialogMetrics.cardVerticalPadding,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: dlg.text,
                          fontSize: BottomDialogMetrics.actionLabelFontSize,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Icon(
                      open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: dlg.textSub,
                      size: BottomDialogMetrics.actionIconSize,
                    ),
                  ],
                ),
              ),
            ),
            if (open) ...[
              Divider(height: 1, thickness: 1, color: dlg.divider),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  BottomDialogMetrics.cardHorizontalPadding,
                  12,
                  BottomDialogMetrics.cardHorizontalPadding,
                  4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _historyBody(YggDialogColors dlg) {
    if (_historyLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: kDlgAccent),
          ),
        ),
      );
    }
    final error = _historyError;
    if (error != null) {
      return Text(
        error,
        style: TextStyle(
          color: dlg.textSub,
          fontSize: BottomDialogMetrics.mediumFontSize,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (_history.isEmpty) {
      return Text(
        '숙제로 낸 적이 없습니다.',
        style: TextStyle(
          color: dlg.textSub,
          fontSize: BottomDialogMetrics.mediumFontSize,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return Column(
      children: [
        for (final brief in _history) _historyCard(dlg, brief),
      ],
    );
  }

  Widget _listLabel(YggDialogColors dlg, String title, {bool padTop = true}) {
    return Padding(
      padding: EdgeInsets.only(top: padTop ? 8 : 0, bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          color: dlg.text,
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _emptyLine(YggDialogColors dlg, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          color: dlg.textSub,
          fontSize: BottomDialogMetrics.mediumFontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _historyCard(YggDialogColors dlg, HomeworkAssignmentBrief brief) {
    final due = brief.dueDate;
    final original = brief.originalDueDate;
    final showOriginal = original != null &&
        due != null &&
        _dateOnly(original) != _dateOnly(due);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(
        horizontal: BottomDialogMetrics.cardHorizontalPadding,
        vertical: BottomDialogMetrics.cardVerticalPadding,
      ),
      decoration: BoxDecoration(
        color: dlg.cardBg,
        borderRadius: BorderRadius.circular(BottomDialogMetrics.cardRadius),
        border: Border.all(color: dlg.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${brief.repeatIndex}회차',
                  style: TextStyle(
                    color: dlg.text,
                    fontSize: BottomDialogMetrics.actionLabelFontSize,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                _historyStatus(brief),
                style: TextStyle(
                  color: dlg.textSub,
                  fontSize: BottomDialogMetrics.smallFontSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '내준  ${_stamp(brief.assignedAt)}',
            style: TextStyle(
              color: dlg.textSub,
              fontSize: BottomDialogMetrics.smallFontSize,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          Text(
            '검사  ${due == null ? '미정' : _stamp(due)}',
            style: TextStyle(
              color: dlg.textSub,
              fontSize: BottomDialogMetrics.smallFontSize,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          if (showOriginal)
            Text(
              '원래  ${_stamp(original)}',
              style: TextStyle(
                color: dlg.textSub,
                fontSize: BottomDialogMetrics.smallFontSize,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
        ],
      ),
    );
  }

  Widget _childCard(YggDialogColors dlg, HomeworkItem child, int index) {
    final title = child.title.trim().isEmpty ? '(제목 없음)' : child.title.trim();
    final page = homeworkItemPageRangeText(
      page: child.page,
      unitMappings: child.unitMappings,
    );
    final count = homeworkItemProblemCount(
      count: child.count,
      unitMappings: child.unitMappings,
    );
    final pageText = page.isEmpty ? 'p.-' : 'p.$page';
    final countText = count > 0 ? '$count문항' : '-문항';
    final type = (child.type ?? '').trim().isEmpty ? '-' : child.type!.trim();
    final memo = (child.memo ?? '').trim();
    final canEditPage = widget.onChildPageTap != null;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: dlg.cardBg,
        borderRadius: BorderRadius.circular(BottomDialogMetrics.cardRadius),
        border: Border.all(color: dlg.cardBorder),
      ),
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: BottomDialogMetrics.cardHorizontalPadding,
            vertical: BottomDialogMetrics.cardVerticalPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: LatexTextRenderer(
                      '${index + 1}. $title',
                      style: TextStyle(
                        color: dlg.text,
                        fontSize: BottomDialogMetrics.actionLabelFontSize,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _stateLabel(child),
                    style: TextStyle(
                      color: dlg.textSub,
                      fontSize: BottomDialogMetrics.smallFontSize,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                type,
                style: TextStyle(
                  color: dlg.textSub,
                  fontSize: BottomDialogMetrics.mediumFontSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: canEditPage
                          ? () => widget.onChildPageTap!(child)
                          : null,
                      child: Text(
                        pageText,
                        style: TextStyle(
                          color: dlg.text,
                          fontSize: BottomDialogMetrics.mediumFontSize,
                          fontWeight: FontWeight.w700,
                          decoration:
                              canEditPage ? TextDecoration.underline : null,
                          decorationColor: dlg.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      countText,
                      style: TextStyle(
                        color: dlg.text,
                        fontSize: BottomDialogMetrics.mediumFontSize,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '검사 ${child.checkCount}회 · 권장 ${_childRecommendedLabel(child)}',
                  style: TextStyle(
                    color: dlg.textSub,
                    fontSize: BottomDialogMetrics.smallFontSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (memo.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    memo,
                    style: TextStyle(
                      color: dlg.hint,
                      fontSize: BottomDialogMetrics.smallFontSize,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _fact(YggDialogColors dlg, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: dlg.textSub,
                fontSize: BottomDialogMetrics.smallFontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: dlg.text,
                fontSize: BottomDialogMetrics.mediumFontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

DateTime? _earliestCreated(List<HomeworkItem> items) {
  DateTime? earliest;
  for (final item in items) {
    final created = item.createdAt;
    if (created != null && (earliest == null || created.isBefore(earliest))) {
      earliest = created;
    }
  }
  return earliest;
}

int _recommendedMinutesOf(HomeworkItem item) {
  final confirmed = item.recommendedMinutes ?? 0;
  if (confirmed > 0) return confirmed;
  return item.recommendedMinutesAuto ?? 0;
}

int _groupRecommendedMinutes(List<HomeworkItem> items) {
  var raw = 0;
  var counted = 0;
  for (final item in items) {
    final value = _recommendedMinutesOf(item);
    if (value <= 0) continue;
    raw += value;
    counted += 1;
  }
  return math.max(
    0,
    raw -
        math.max(0, counted - 1) *
            HomeworkTimeDefaultsService.initialAlphaMinutes,
  );
}

String _childRecommendedLabel(HomeworkItem item) {
  final minutes = _recommendedMinutesOf(item);
  if (minutes <= 0) return '-';
  return _minutesLabel(minutes);
}

String _limitLabel(List<HomeworkItem> items) {
  final limits = <int>{
    for (final item in items)
      if ((item.timeLimitMinutes ?? 0) > 0) item.timeLimitMinutes!,
  };
  if (limits.isEmpty) return '-';
  final sorted = limits.toList(growable: false)..sort();
  return sorted.map((minutes) => '$minutes분').join(' · ');
}

bool _isTestItem(HomeworkItem item) {
  if ((item.type ?? '').trim() == '테스트') return true;
  if ((item.testOriginFlowId ?? '').trim().isNotEmpty) return true;
  return (item.sourceUnitLevel ?? '').trim() == 'naesin' &&
      (item.timeLimitMinutes ?? 0) > 0;
}

int _totalMinutes(HomeworkItem summary) {
  final runningMs = summary.runStart == null
      ? 0
      : DateTime.now().difference(summary.runStart!).inMilliseconds;
  return math.max(0, summary.accumulatedMs + runningMs) ~/ 60000;
}

String _elapsedLabel(HomeworkItem summary, List<HomeworkItem> children) {
  final runningMs = summary.runStart == null
      ? 0
      : DateTime.now().difference(summary.runStart!).inMilliseconds;
  final totalMs = summary.accumulatedMs + runningMs;
  final isTest = children.any(_isTestItem);
  if (isTest) return _minutesLabel(math.max(0, totalMs) ~/ 60000);
  final cycleMs = math.max(0, totalMs - summary.cycleBaseAccumulatedMs);
  final paused = summary.phase == 1 &&
      cycleMs > 0 &&
      summary.firstStartedAt != null;
  final shown = (summary.phase == 1 && !paused) ? 0 : cycleMs;
  return _minutesLabel(shown ~/ 60000);
}

String _minutesLabel(int minutes) {
  final safe = math.max(0, minutes);
  if (safe <= 0) return '0분';
  final hours = safe ~/ 60;
  final remain = safe % 60;
  if (hours <= 0) return '$remain분';
  if (remain == 0) return '$hours시간';
  return '$hours시간 $remain분';
}

String _stateLabel(HomeworkItem item) {
  if (item.status == HomeworkStatus.completed || item.phase == 0) return '완료';
  final phase = switch (item.phase) {
    1 => '대기',
    2 => '수행',
    3 => '제출',
    4 => '확인',
    _ => '-',
  };
  if (item.status == HomeworkStatus.homework) return '$phase · 숙제';
  return phase;
}

String _clock(DateTime? value) {
  if (value == null) return '-';
  return _stamp(value.toLocal());
}

String _stamp(DateTime value) {
  final local = value.toLocal();
  const week = ['월', '화', '수', '목', '금', '토', '일'];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.month)}.${two(local.day)} (${week[local.weekday - 1]}) '
      '${two(local.hour)}:${two(local.minute)}';
}

DateTime _dateOnly(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

String _historyStatus(HomeworkAssignmentBrief brief) {
  if (brief.isSelfExtra) return '추가 검사';
  if (brief.status.trim() == 'not_done_to_class') return '안 함 → 수업 전환';
  if (brief.absenceCarryover) return '결석 이월';
  switch (brief.status.trim()) {
    case 'carried_over':
      return '이월됨';
    case 'carried_to_class':
      return '수업 이월';
    case 'completed':
      return '완료';
    case 'in_progress':
      return '진행중';
    default:
      break;
  }
  final original = brief.originalDueDate;
  final due = brief.dueDate;
  if (original != null &&
      due != null &&
      _dateOnly(original).isBefore(_dateOnly(due))) {
    return '미검사 이월';
  }
  return '내줌';
}
