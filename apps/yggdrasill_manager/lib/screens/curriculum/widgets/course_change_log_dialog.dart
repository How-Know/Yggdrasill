import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/course_map_controller.dart';
import '../../../services/course_map_service.dart';
import '../../think/think_style.dart';

/// 교육과정 흐름 배치와 개념 본문·서술을 고친 기록을 새것부터 본다(읽기만, `docs/architecture/course-map.md`).
Future<void> showCourseChangeLog(BuildContext context,
    {required CourseMapController controller, ValueChanged<String>? onOpenConcept}) {
  return showDialog<void>(
    context: context,
    builder: (_) => CourseChangeLogDialog(controller: controller, onOpenConcept: onOpenConcept),
  );
}

class CourseChangeLogDialog extends StatefulWidget {
  const CourseChangeLogDialog({super.key, required this.controller, this.onOpenConcept});

  final CourseMapController controller;

  /// 개념 이름을 누르면 창을 닫고 부른다. 없으면 이름은 보기만 한다.
  final ValueChanged<String>? onOpenConcept;

  @override
  State<CourseChangeLogDialog> createState() => _CourseChangeLogDialogState();
}

class _CourseChangeLogDialogState extends State<CourseChangeLogDialog> {
  final ScrollController _scroll = ScrollController();
  final List<CourseChange> _items = [];
  bool _placements = true;
  bool _edits = true;
  bool _more = false;
  bool _loading = false;
  CourseMapException? _error;
  int _token = 0;

  List<String>? get _kinds => _placements && _edits
      ? null
      : [
          if (_placements) kCourseChangePlacement,
          if (_edits) ...[kCourseChangeContent, kCourseChangeStatement],
        ];

  @override
  void initState() {
    super.initState();
    _loading = true;
    unawaited(_fetch(++_token, more: false));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 처음부터 다시 읽을 때는 보이던 줄을 먼저 비운다. 실패하면 오류만 남는다.
  Future<void> _load({bool more = false}) async {
    final token = ++_token;
    final kinds = _kinds;
    setState(() {
      _error = null;
      if (!more) {
        _items.clear();
        _more = false;
      }
      _loading = kinds == null || kinds.isNotEmpty;
    });
    if (_loading) await _fetch(token, more: more);
  }

  Future<void> _fetch(int token, {required bool more}) async {
    final kinds = _kinds;
    try {
      final page = await widget.controller
          .recentChanges(kinds: kinds, olderThan: more && _items.isNotEmpty ? _items.last : null);
      if (!mounted || token != _token) return;
      setState(() {
        _items.addAll(page.items);
        _more = page.more;
        _loading = false;
      });
    } on CourseMapException catch (e) {
      if (!mounted || token != _token) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _open(String conceptId) {
    final open = widget.onOpenConcept;
    if (open == null) return;
    Navigator.pop(context);
    open(conceptId);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: math.min(720, size.width - 48),
        height: math.min(680, size.height - 48),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.history, color: kThinkAccent, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('최근 변경 기록',
                        style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    tooltip: '다시 읽기',
                    onPressed: _loading ? null : () => unawaited(_load()),
                    icon: const Icon(Icons.refresh, size: 18),
                    color: kThinkSub,
                  ),
                  IconButton(
                    tooltip: '닫기',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                    color: kThinkSub,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '교육과정 흐름에 개념을 놓고·옮기고·뺀 기록과 개념 본문·서술을 고친 기록을 새것부터 보입니다. 읽기만 합니다.',
                style: TextStyle(color: kThinkSub, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ThinkToggleChip(
                    key: const ValueKey('change-filter-placement'),
                    label: '배치',
                    icon: Icons.timeline,
                    selected: _placements,
                    tooltip: '교육과정 흐름 단원에 놓기·옮기기·빼기',
                    onChanged: (v) {
                      _placements = v;
                      unawaited(_load());
                    },
                  ),
                  ThinkToggleChip(
                    key: const ValueKey('change-filter-edits'),
                    label: '본문·서술',
                    icon: Icons.edit_note,
                    selected: _edits,
                    tooltip: '개념 이름·본문 고침, 서술 확정',
                    onChanged: (v) {
                      _edits = v;
                      unawaited(_load());
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorView(CourseMapException e) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ThinkNotice(
          text: e.notReady
              ? 'DB에 변경 기록 기능이 아직 반영되지 않았습니다. 반영(마이그레이션)은 별도 승인 뒤에 합니다.'
              : '변경 기록을 읽지 못했습니다: ${e.message}',
          color: e.notReady ? kThinkBlue : kThinkError,
          icon: e.notReady ? Icons.info_outline : Icons.error_outline,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => unawaited(_load(more: _items.isNotEmpty)),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('다시 읽기'),
            style: TextButton.styleFrom(foregroundColor: kThinkAccent),
          ),
        ),
      ],
    );
  }

  Widget _body() {
    if (!_placements && !_edits) {
      return const Center(child: Text('보여 줄 종류를 하나 이상 고르세요.', style: TextStyle(color: kThinkHint, fontSize: 13)));
    }
    final error = _error;
    if (_items.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator(color: kThinkAccent));
      if (error != null) return SingleChildScrollView(child: _errorView(error));
      return const Center(child: Text('아직 남은 기록이 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13)));
    }
    final entries = <Object>[];
    String? day;
    for (final c in _items) {
      final label = _dayLabel(c.time);
      if (label != day) {
        entries.add(label);
        day = label;
      }
      entries.add(c);
    }
    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        itemCount: entries.length + 1,
        itemBuilder: (context, i) {
          if (i == entries.length) return _footer(error);
          final e = entries[i];
          if (e is String) {
            return Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 12, bottom: 8),
              child: Text(e, style: const TextStyle(color: kThinkSub, fontSize: 13, fontWeight: FontWeight.w800)),
            );
          }
          final c = e as CourseChange;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ChangeTile(change: c, onOpen: widget.onOpenConcept == null ? null : () => _open(c.conceptId)),
          );
        },
      ),
    );
  }

  Widget _footer(CourseMapException? error) {
    if (error != null) {
      return Padding(padding: const EdgeInsets.only(top: 8), child: _errorView(error));
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(color: kThinkAccent)),
      );
    }
    if (!_more) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: Text('여기까지입니다.', style: TextStyle(color: kThinkHint, fontSize: 12))),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: OutlinedButton.icon(
          key: const ValueKey('change-log-more'),
          onPressed: () => unawaited(_load(more: true)),
          style: thinkOutlineButton(),
          icon: const Icon(Icons.expand_more, size: 16),
          label: const Text('더 보기'),
        ),
      ),
    );
  }
}

String _two(int v) => v.toString().padLeft(2, '0');

String _dayLabel(DateTime? t) {
  if (t == null) return '시각 모름';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '오늘';
  if (diff == 1) return '어제';
  return '${t.year}-${_two(t.month)}-${_two(t.day)}';
}

String _path(List<String> names) => names.isEmpty ? '(단원 위치를 알 수 없음)' : names.join(' > ');

class _ChangeTile extends StatelessWidget {
  const _ChangeTile({required this.change, this.onOpen});

  final CourseChange change;
  final VoidCallback? onOpen;

  (String, Color) _action() {
    final c = change;
    switch (c.kind) {
      case kCourseChangePlacement:
        return switch (c.action) {
          'move' => ('옮김', kThinkLink),
          'remove' => ('뺌', kThinkError),
          _ => ('놓음', kThinkAccent),
        };
      case kCourseChangeContent:
        if (c.renamed && c.contentChanged) return ('이름·본문 고침', kThinkBlue);
        if (c.renamed) return ('이름 고침', kThinkBlue);
        return ('본문 고침', kThinkBlue);
      default:
        return ('서술 확정', kThinkSuccess);
    }
  }

  (String, Color, String)? _origin() {
    final c = change;
    switch (c.kind) {
      case kCourseChangePlacement:
        return c.byThink
            ? ('Think 카드', kThinkLink, '대화에서 Think가 제안한 카드를 승인해 반영됐습니다.')
            : ('직접', kThinkSub, '운영자가 화면에서 바로 바꿨습니다.');
      case kCourseChangeContent:
        if (c.via == 'draft') {
          return c.byThink
              ? ('Think 수정안 확정', kThinkLink, 'Think가 쓴 수정안을 운영자가 확정했습니다.')
              : ('수정안 확정', kThinkSub, '운영자가 쓴 수정안을 확정했습니다.');
        }
        return ('직접', kThinkSub, '운영자가 개념 화면에서 바로 고쳤습니다.');
      default:
        return null;
    }
  }

  String _detail() {
    final c = change;
    switch (c.kind) {
      case kCourseChangePlacement:
        final course = (c.courseName ?? '').trim();
        final prefix = course.isEmpty ? '' : '$course · ';
        return switch (c.action) {
          'move' => '$prefix${_path(c.fromPath)}  →  ${_path(c.path)}',
          'remove' => '$prefix${_path(c.fromPath)}에서 뺌',
          _ => c.beforeLog ? '$prefix지금 위치: ${_path(c.path)}' : '$prefix${_path(c.path)}',
        };
      case kCourseChangeContent:
        final before = (c.beforeName ?? '').trim();
        final after = (c.afterName ?? '').trim();
        final rename = '"$before" → "$after"';
        if (c.renamed && c.contentChanged) return '$rename · 본문도 고침';
        if (c.renamed) return rename;
        return '본문 내용을 고침';
      default:
        final v = c.version == null ? '' : ' v${c.version}';
        if (c.role == 'core') return '공통 내용$v 확정';
        final title = (c.title ?? '').trim();
        return title.isEmpty ? '서술$v 확정' : '서술 "$title"$v 확정';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = change;
    final (label, color) = _action();
    final origin = _origin();
    final time = c.time;
    final note = (c.note ?? '').trim();
    final name = Text(c.conceptName.trim().isEmpty ? '(이름 없음)' : c.conceptName.trim(),
        style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700));
    return Container(
      key: ValueKey('change-${c.key}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(time == null ? '--:--' : '${_two(time.hour)}:${_two(time.minute)}',
                  style: const TextStyle(color: kThinkHint, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ThinkBadge(label, color: color),
                    if (origin != null) Tooltip(message: origin.$3, child: ThinkBadge(origin.$1, color: origin.$2)),
                    if (c.beforeLog)
                      const Tooltip(
                        message: '배치 기록을 시작하기 전에 놓인 개념입니다. 놓은 시각과 지금 위치만 알 수 있습니다.',
                        child: ThinkBadge('기록 시작 전', color: kThinkHint),
                      ),
                    if (onOpen == null)
                      name
                    else
                      Tooltip(
                        message: '라이브러리에서 열기',
                        child: InkWell(
                          key: ValueKey('change-open-${c.key}'),
                          onTap: onOpen,
                          borderRadius: BorderRadius.circular(4),
                          child: name,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_detail(), style: const TextStyle(color: kThinkSub, fontSize: 12)),
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    c.kind == kCourseChangePlacement && c.byThink ? 'Think 근거: $note' : '메모: $note',
                    style: const TextStyle(color: kThinkHint, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
