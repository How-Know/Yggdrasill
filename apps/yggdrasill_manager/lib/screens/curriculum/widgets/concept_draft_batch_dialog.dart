import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/concept_book_service.dart';
import '../../../services/concept_draft_models.dart';
import '../../../services/concept_draft_service.dart';
import '../../../services/concept_library_service.dart';
import '../../think/think_style.dart';
import 'concept_draft_batch_confirm.dart';
import 'concept_workspace.dart';

/// 고른 중단원의 소단원 초안을 차례로(한 번에 하나씩) 만든다. 다 만든 뒤 운영자가 누르면 이번에 만든 초안을 한 번에 확정한다.
/// 돌려주는 값은 초안을 하나라도 만들었는지. onConfirmed: 한 번에 확정해 라이브러리가 바뀌었을 때.
Future<bool> showConceptDraftBatchDialog(
  BuildContext context, {
  required ConceptBookEntry book,
  required List<ConceptBookUnitPages> units,
  required List<ConceptCriterion> criteria,
  ConceptDraftService? service,
  Duration rateLimitWait = const Duration(seconds: 65),
  VoidCallback? onConfirmed,
}) async {
  final made = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ConceptDraftBatchDialog(
      book: book,
      units: units,
      criteria: criteria,
      service: service,
      rateLimitWait: rateLimitWait,
      onConfirmed: onConfirmed,
    ),
  );
  return made ?? false;
}

enum _UnitState { waiting, running, done, folderFailed, failed, stopped }

/// 이 오류가 나면 다음 소단원도 같은 이유로 실패하므로 전체를 멈춘다.
const Set<String> _stopAllCodes = {
  'budget_exceeded',
  'ai_not_configured',
  'unauthorized',
  'forbidden',
  'book_forbidden',
  'masks_mismatch',
};

class ConceptDraftBatchDialog extends StatefulWidget {
  const ConceptDraftBatchDialog({
    super.key,
    required this.book,
    required this.units,
    required this.criteria,
    this.service,
    this.rateLimitWait = const Duration(seconds: 65),
    this.onConfirmed,
  });

  final ConceptBookEntry book;
  final List<ConceptBookUnitPages> units;
  final List<ConceptCriterion> criteria;
  final ConceptDraftService? service;
  final VoidCallback? onConfirmed;

  /// 요청 제한(분당 횟수)에 걸리면 이만큼 기다렸다가 같은 단계를 한 번 다시 한다.
  final Duration rateLimitWait;

  @override
  State<ConceptDraftBatchDialog> createState() => _ConceptDraftBatchDialogState();
}

class _ConceptDraftBatchDialogState extends State<ConceptDraftBatchDialog> {
  late final ConceptDraftService _svc = widget.service ?? ConceptDraftService();
  late final Set<String> _criteria = {
    for (final c in widget.criteria.where((c) => c.confirmed).take(10)) c.id,
  };
  late final List<_UnitState> _states = List.filled(widget.units.length, _UnitState.waiting);
  late final List<String?> _messages = List.filled(widget.units.length, null);

  /// 이 창에서 만든 초안 id(건너뛴 소단원은 비어 있다).
  late final List<String?> _draftIds = List.filled(widget.units.length, null);
  final Set<String> _confirmedIds = {};
  bool _confirming = false;
  String? _confirmProgress;
  String? _confirmNotice;
  bool _confirmError = false;

  Map<int, Set<int>>? _reads;
  String? _readsError;
  bool _running = false;
  bool _stopRequested = false;
  bool _finished = false;
  String? _stopReason;
  int _made = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadReads());
  }

  Future<void> _loadReads() async {
    try {
      final pages = {
        for (final u in widget.units)
          for (final p in u.pages) p.rawPage
      }.toList()
        ..sort();
      final reads = await _svc.transcribedReads(widget.book, pages);
      if (mounted) setState(() => _reads = reads);
    } catch (e) {
      if (mounted) setState(() => _readsError = '저장된 전사를 읽지 못했습니다: $e');
    }
  }

  int _readsToDo(ConceptBookUnitPages u) {
    final reads = _reads ?? const <int, Set<int>>{};
    var n = 0;
    for (final p in u.pages) {
      n += 2 - (reads[p.rawPage]?.length ?? 0).clamp(0, 2);
    }
    return n;
  }

  double get _cost => widget.units.fold(0.0, (sum, u) => sum + conceptDraftCostEstimate(_readsToDo(u)));

  Future<void> _start() async {
    final ok = await confirmThink(
      context,
      title: '소단원 ${widget.units.length}개를 차례로 만들까요?',
      message: [
        '한 번에 하나씩 쪽 전사 → 개념 초안 정리 → 폴더 제안을 합니다. 예상 비용 약 \$${_cost.toStringAsFixed(2)}(시범 실측 기준 대략값).',
        '만드는 동안에는 라이브러리에 넣지 않습니다. 다 만든 뒤 이 창에서 한 번에 확정하거나, "개념 초안" 목록에서 하나씩 검토합니다.',
        '"멈추기"를 누르면 지금 하던 소단원까지 하고 멈춥니다. 만들어진 초안과 전사는 남고, 다시 고르면 남은 것만 합니다.',
      ].join('\n\n'),
      confirmLabel: '시작',
    );
    if (!ok || !mounted) return;
    setState(() {
      _running = true;
      _stopRequested = false;
      _stopReason = null;
    });
    try {
      final cov = await _svc.coverage();
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < widget.units.length; i += 1) {
          if (_states[i] == _UnitState.done || _states[i] == _UnitState.folderFailed) continue;
          if (cov.unit(widget.book, widget.units[i].path).state != ConceptUnitDraftState.none) {
            _states[i] = _UnitState.done;
            _messages[i] = '이미 초안이 있어 건너뛰었습니다.';
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _stopReason = '초안 기록을 읽지 못해 시작하지 않았습니다(같은 소단원을 두 번 만들지 않으려고): $e';
      });
      return;
    }
    for (var i = 0; i < widget.units.length; i += 1) {
      if (!mounted) return;
      if (_states[i] == _UnitState.done || _states[i] == _UnitState.folderFailed) continue;
      if (_stopRequested || _stopReason != null) {
        setState(() => _states[i] = _UnitState.stopped);
        continue;
      }
      await _runUnit(i);
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _finished = true;
    });
  }

  /// 요청 제한이면 기다렸다가 한 번 더 한다.
  Future<T> _withRetry<T>(int i, Future<T> Function() call) async {
    try {
      return await call();
    } on ConceptDraftException catch (e) {
      if (e.code != 'rate_limited' || !mounted) rethrow;
      setState(() => _messages[i] = '요청이 많아 ${widget.rateLimitWait.inSeconds}초 기다린 뒤 다시 합니다.');
      await Future<void>.delayed(widget.rateLimitWait);
      return await call();
    }
  }

  Future<void> _runUnit(int i) async {
    final u = widget.units[i];
    final pages = [for (final p in u.pages) p.rawPage];
    void say(String s) {
      if (mounted) setState(() => _messages[i] = s);
    }

    setState(() {
      _states[i] = _UnitState.running;
      _messages[i] = null;
    });
    String? draftId;
    try {
      await _withRetry(
          i,
          () => _svc.transcribe(
                book: widget.book,
                unitPath: u.path,
                pages: pages,
                onProgress: (s, d, t) => say(t > 0 ? '$s ($d/$t)' : s),
              ));
      say(conceptDraftWaitText('개념 초안을 정리하는 중', null));
      draftId = await _withRetry(
          i,
          () => _svc.createDraft(
                book: widget.book,
                unitPath: u.path,
                pages: pages,
                criterionIds: _criteria.toList(),
                onWait: (e) => say(conceptDraftWaitText('개념 초안을 정리하는 중', e)),
              ));
      _made += 1;
      _draftIds[i] = draftId;
      say('넣을 폴더를 제안하는 중');
      await _withRetry(i, () => _svc.proposeFolders(draftId!));
      if (!mounted) return;
      setState(() {
        _states[i] = _UnitState.done;
        _messages[i] = '초안을 만들었습니다.';
      });
    } catch (e) {
      if (!mounted) return;
      final code = e is ConceptDraftException ? e.code : '';
      final text = e is ConceptDraftException && e.pages.isNotEmpty ? '${e.message} (${e.pages.join(', ')}쪽)' : '$e';
      setState(() {
        if (draftId != null) {
          _states[i] = _UnitState.folderFailed;
          _messages[i] = '초안은 만들었지만 폴더 제안을 하지 못했습니다(검토 화면에서 폴더를 정하면 됩니다): $text';
        } else {
          _states[i] = _UnitState.failed;
          _messages[i] = text;
        }
        if (_stopAllCodes.contains(code)) _stopReason = '$text — 남은 소단원은 하지 않았습니다.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final reads = _reads;
    final failed = _states.where((s) => s == _UnitState.failed).length;
    return PopScope(
      canPop: !_running && !_confirming,
      child: Dialog(
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
                    const Icon(Icons.playlist_play, color: kThinkAccent, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('개념 초안 이어서 만들기',
                          style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
                    ),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: _running || _confirming ? null : () => Navigator.pop(context, _made > 0),
                      icon: const Icon(Icons.close, size: 20),
                      color: kThinkSub,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                    '${widget.book.bookName ?? '(책 이름을 볼 수 없음)'} · ${widget.book.gradeLabel} · 소단원 ${widget.units.length}개',
                    style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const ConceptHint('한 번에 하나씩 차례로 만듭니다. 만드는 동안에는 확정하지 않습니다. 다 만든 뒤 "만든 초안 한 번에 확정"을 누르면 '
                    '검토 없이 AI 초안·폴더 제안 그대로 넣고, 하나씩 보려면 "개념 초안" 목록에서 검토합니다.'),
                const SizedBox(height: 8),
                if (_readsError != null)
                  ThinkNotice(text: _readsError!, color: kThinkError, icon: Icons.error_outline)
                else
                  ConceptHint(reads == null
                      ? '저장된 전사를 확인하는 중'
                      : '읽을 횟수 ${widget.units.fold<int>(0, (s, u) => s + _readsToDo(u))}번 남음 · 예상 비용 약 \$${_cost.toStringAsFixed(2)} (시범 실측 기준 대략값)'),
                if (widget.criteria.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in widget.criteria)
                        ThinkToggleChip(
                          label: '${c.title ?? c.draftTitle ?? ''}${c.confirmed ? ' v${c.version}' : ' (초안)'}',
                          icon: Icons.rule_folder_outlined,
                          selected: _criteria.contains(c.id),
                          enabled: !_running && !_finished,
                          onChanged: (v) => setState(() {
                            if (v && _criteria.length < 10) {
                              _criteria.add(c.id);
                            } else {
                              _criteria.remove(c.id);
                            }
                          }),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                const Divider(color: kThinkBorder, height: 1),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: widget.units.length,
                    itemBuilder: (context, i) => _unitRow(i),
                  ),
                ),
                if (_stopReason != null) ...[
                  ThinkNotice(text: _stopReason!, color: kThinkError, icon: Icons.error_outline),
                  const SizedBox(height: 8),
                ],
                if (_finished && _stopReason == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ThinkNotice(
                      text: '초안 $_made개를 만들었습니다${failed > 0 ? '(실패 $failed개는 다시 시작하면 남은 것만 합니다)' : ''}. '
                          '"만든 초안 한 번에 확정"으로 바로 넣거나, "개념 초안" 목록에서 하나씩 검토하세요.',
                      color: failed > 0 ? kThinkAccent : kThinkSuccess,
                      icon: failed > 0 ? Icons.info_outline : Icons.check_circle_outline,
                    ),
                  ),
                if (_confirmNotice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ThinkNotice(
                      text: _confirmNotice!,
                      color: _confirmError ? kThinkError : kThinkSuccess,
                      icon: _confirmError ? Icons.error_outline : Icons.check_circle_outline,
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_confirmProgress != null) ...[
                      Expanded(
                        child: Text(_confirmProgress!,
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kThinkSub, fontSize: 13)),
                      ),
                      const SizedBox(width: 10),
                      const SizedBox(
                          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent)),
                      const SizedBox(width: 10),
                    ],
                    if (!_running && _toConfirm.isNotEmpty) ...[
                      OutlinedButton.icon(
                        key: const ValueKey('batch-confirm-made'),
                        onPressed: _confirming ? null : () => unawaited(_confirmMade()),
                        style: thinkOutlineButton(),
                        icon: const Icon(Icons.done_all, size: 18),
                        label: Text('만든 초안 ${_toConfirm.length}개 한 번에 확정'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (_running)
                      TextButton(
                        onPressed: _stopRequested ? null : () => setState(() => _stopRequested = true),
                        child: Text(_stopRequested ? '지금 소단원까지 하고 멈춥니다' : '멈추기',
                            style: const TextStyle(color: kThinkLink)),
                      )
                    else
                      ElevatedButton.icon(
                        onPressed: reads == null || widget.units.isEmpty || !_hasWork || _confirming
                            ? null
                            : () => unawaited(_start()),
                        style: thinkPrimaryButton(),
                        icon: Icon(_finished ? Icons.refresh : Icons.play_arrow, size: 18),
                        label: Text(_finished ? '남은 것 다시 하기' : '차례로 만들기'),
                      ),
                    if (_running) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _hasWork => _states.any((s) => s != _UnitState.done && s != _UnitState.folderFailed);

  List<String> get _toConfirm => [
        for (final id in _draftIds)
          if (id != null && !_confirmedIds.contains(id)) id,
      ];

  Future<void> _confirmMade() async {
    final ids = _toConfirm;
    setState(() {
      _confirming = true;
      _confirmNotice = null;
    });
    DraftBatchOutcome? outcome;
    try {
      outcome = await confirmDraftBatch(
        context,
        service: _svc,
        ids: ids,
        onProgress: (p) {
          if (mounted) setState(() => _confirmProgress = p);
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _confirming = false;
        _confirmNotice = '확정 전에 초안을 읽지 못했습니다: $e';
        _confirmError = true;
      });
      return;
    }
    if (!mounted) return;
    if (outcome == null) {
      setState(() => _confirming = false);
      return;
    }
    if (outcome.done > 0) widget.onConfirmed?.call();
    setState(() {
      _confirming = false;
      _confirmedIds.addAll(outcome!.confirmedIds);
      _confirmNotice = outcome.message;
      _confirmError = outcome.failed.isNotEmpty;
    });
  }

  Widget _unitRow(int i) {
    final u = widget.units[i];
    final (icon, color, label) = switch (_states[i]) {
      _UnitState.waiting => (Icons.radio_button_unchecked, kThinkHint, '대기'),
      _UnitState.running => (Icons.timelapse, kThinkAccent, '만드는 중'),
      _UnitState.done => (Icons.check_circle, kThinkSuccess, '완료'),
      _UnitState.folderFailed => (Icons.check_circle_outline, kThinkAccent, '폴더 제안 없음'),
      _UnitState.failed => (Icons.error_outline, kThinkError, '실패'),
      _UnitState.stopped => (Icons.pause_circle_outline, kThinkHint, '멈춤'),
    };
    final msg = _messages[i];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(u.path.isEmpty ? '(이름 없는 소단원)' : u.path.last,
                    style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
                Text(
                  '${u.path.length >= 2 ? '${u.path[u.path.length - 2]} · ' : ''}PDF ${u.startPage}–${u.endPage}쪽(${u.pages.length}쪽)',
                  style: const TextStyle(color: kThinkSub, fontSize: 12),
                ),
                if (msg != null)
                  Text(msg,
                      style: TextStyle(color: _states[i] == _UnitState.failed ? kThinkError : kThinkSub, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ThinkBadge(label, color: color),
        ],
      ),
    );
  }
}
