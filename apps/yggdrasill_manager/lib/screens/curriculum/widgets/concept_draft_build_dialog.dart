import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/concept_book_service.dart';
import '../../../services/concept_draft_models.dart';
import '../../../services/concept_draft_service.dart';
import '../../../services/concept_library_service.dart';
import '../../think/think_style.dart';
import 'concept_workspace.dart';

/// 소단원 하나로 개념 초안을 만든다. 돌려주는 값은 검토할 초안 id(만들지 않고 닫으면 null).
Future<String?> showConceptDraftBuildDialog(
  BuildContext context, {
  required ConceptBookEntry book,
  required ConceptBookUnitPages unit,
  required List<ConceptCriterion> criteria,
  ConceptDraftService? service,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ConceptDraftBuildDialog(book: book, unit: unit, criteria: criteria, service: service),
  );
}

enum _Step { transcribe, organize, folders }

/// 쪽마다 두 번 전사 → 개념 초안 정리 → 폴더 제안. 모두 서버에 저장되므로 중간에 멈춰도 다시 누르면 이어서 한다.
/// 라이브러리에는 아무것도 넣지 않는다(검토 화면에서 확정할 때만).
class ConceptDraftBuildDialog extends StatefulWidget {
  const ConceptDraftBuildDialog({
    super.key,
    required this.book,
    required this.unit,
    required this.criteria,
    this.service,
  });

  final ConceptBookEntry book;
  final ConceptBookUnitPages unit;
  final List<ConceptCriterion> criteria;
  final ConceptDraftService? service;

  @override
  State<ConceptDraftBuildDialog> createState() => _ConceptDraftBuildDialogState();
}

class _ConceptDraftBuildDialogState extends State<ConceptDraftBuildDialog> {
  late final ConceptDraftService _svc = widget.service ?? ConceptDraftService();
  late final List<int> _pages = [for (final p in widget.unit.pages) p.rawPage];
  late final Set<String> _criteria = {
    for (final c in widget.criteria.where((c) => c.confirmed).take(10)) c.id,
  };

  Map<int, Set<int>>? _reads;
  String? _readsError;
  bool _running = false;
  _Step? _failedAt;
  String? _error;
  String? _progress;
  final Set<_Step> _done = {};
  String? _draftId;

  @override
  void initState() {
    super.initState();
    unawaited(_loadReads());
  }

  Future<void> _loadReads() async {
    try {
      final reads = await _svc.transcribedReads(widget.book, _pages);
      if (mounted) setState(() => _reads = reads);
    } catch (e) {
      if (mounted) setState(() => _readsError = '저장된 전사를 읽지 못했습니다: $e');
    }
  }

  int get _readsToDo {
    final reads = _reads ?? const <int, Set<int>>{};
    var n = 0;
    for (final p in _pages) {
      n += 2 - (reads[p]?.length ?? 0).clamp(0, 2);
    }
    return n;
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _failedAt = null;
    });
    var step = _Step.transcribe;
    try {
      if (_draftId == null) {
        if (!_done.contains(_Step.transcribe)) {
          await _svc.transcribe(
            book: widget.book,
            unitPath: widget.unit.path,
            pages: _pages,
            onProgress: (s, d, t) {
              if (mounted) setState(() => _progress = t > 0 ? '$s ($d/$t)' : s);
            },
          );
          if (!mounted) return;
          setState(() => _done.add(_Step.transcribe));
        }
        step = _Step.organize;
        setState(() => _progress = conceptDraftWaitText('개념 초안을 정리하는 중', null));
        final id = await _svc.createDraft(
          book: widget.book,
          unitPath: widget.unit.path,
          pages: _pages,
          criterionIds: _criteria.toList(),
          onWait: (e) {
            if (mounted) setState(() => _progress = conceptDraftWaitText('개념 초안을 정리하는 중', e));
          },
        );
        if (!mounted) return;
        setState(() {
          _draftId = id;
          _done.add(_Step.organize);
        });
      }
      step = _Step.folders;
      setState(() => _progress = '넣을 폴더를 제안하는 중');
      await _svc.proposeFolders(_draftId!);
      if (!mounted) return;
      setState(() {
        _done.add(_Step.folders);
        _running = false;
        _progress = null;
      });
      Navigator.pop(context, _draftId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _failedAt = step;
        _progress = null;
        _error = e is ConceptDraftException && e.pages.isNotEmpty ? '${e.message} (${e.pages.join(', ')}쪽)' : '$e';
      });
      if (step == _Step.transcribe) unawaited(_loadReads());
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final u = widget.unit;
    final reads = _reads;
    final cost = conceptDraftCostEstimate(_readsToDo);
    return Dialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: math.min(640, size.width - 48),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome_outlined, color: kThinkAccent, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('개념 초안 만들기',
                        style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    tooltip: '닫기',
                    onPressed: _running ? null : () => Navigator.pop(context, _draftId),
                    icon: const Icon(Icons.close, size: 20),
                    color: kThinkSub,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text('${widget.book.bookName ?? '(책 이름을 볼 수 없음)'} · ${widget.book.gradeLabel}',
                  style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(u.path.join(' > '), style: const TextStyle(color: kThinkSub, fontSize: 13)),
              const SizedBox(height: 12),
              const ConceptHint(
                '쪽마다 문항 영역을 회색으로 가린 뒤 두 번 옮겨 적고, 두 결과를 맞춰 개념 초안과 넣을 폴더를 제안합니다. '
                '라이브러리에는 아무것도 넣지 않습니다. 검토 화면에서 고치고 확정할 때만 들어갑니다.',
              ),
              const SizedBox(height: 14),
              const ConceptSectionTitle('쪽'),
              if (_readsError != null)
                ThinkNotice(text: _readsError!, color: kThinkError, icon: Icons.error_outline)
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in u.pages)
                      ThinkBadge(
                        '${p.rawPage}쪽${reads == null ? '' : ' · ${_readLabel(reads[p.rawPage]?.length ?? 0)}'}',
                        color: (reads?[p.rawPage]?.length ?? 0) >= 2 ? kThinkSuccess : kThinkSub,
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              ConceptHint(reads == null
                  ? '저장된 전사를 확인하는 중'
                  : '읽을 횟수 $_readsToDo번 남음 · 예상 비용 약 \$${cost.toStringAsFixed(2)} (시범 실측 기준 대략값)'),
              if (widget.criteria.isNotEmpty) ...[
                const SizedBox(height: 14),
                const ConceptSectionTitle('정리 기준'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in widget.criteria)
                      ThinkToggleChip(
                        label: '${c.title ?? c.draftTitle ?? ''}${c.confirmed ? ' v${c.version}' : ' (초안)'}',
                        icon: Icons.rule_folder_outlined,
                        selected: _criteria.contains(c.id),
                        enabled: !_running && _draftId == null,
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
                const SizedBox(height: 6),
                const ConceptHint('확정 기준은 따르고, 초안 기준은 참고만 합니다. 최대 10개.'),
              ],
              const SizedBox(height: 16),
              _stepRow(_Step.transcribe, '쪽 전사(쪽마다 두 번)'),
              _stepRow(_Step.organize, '개념 초안 정리'),
              _stepRow(_Step.folders, '넣을 폴더 제안'),
              if (_progress != null) ...[
                const SizedBox(height: 8),
                Text(_progress!, style: const TextStyle(color: kThinkSub, fontSize: 13)),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_failedAt == _Step.folders && _draftId != null) ...[
                    TextButton(
                      onPressed: _running ? null : () => Navigator.pop(context, _draftId),
                      child: const Text('폴더 제안 없이 검토하기', style: TextStyle(color: kThinkLink)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  ElevatedButton.icon(
                    onPressed: _running || reads == null || _pages.isEmpty ? null : () => unawaited(_run()),
                    style: thinkPrimaryButton(),
                    icon: _running
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Icon(_failedAt != null ? Icons.refresh : Icons.play_arrow, size: 18),
                    label: Text(_running ? '만드는 중' : (_failedAt != null ? '이어서 다시 하기' : '초안 만들기')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _readLabel(int n) => n >= 2 ? '전사 있음' : (n == 1 ? '한 번 읽음' : '전사 전');

  Widget _stepRow(_Step step, String label) {
    final done = _done.contains(step);
    final failed = _failedAt == step;
    final active = _running && !done && (_Step.values.indexOf(step) == _done.length);
    final (icon, color) = done
        ? (Icons.check_circle, kThinkSuccess)
        : failed
            ? (Icons.error_outline, kThinkError)
            : active
                ? (Icons.timelapse, kThinkAccent)
                : (Icons.radio_button_unchecked, kThinkHint);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: done || active ? kThinkText : kThinkSub, fontSize: 14)),
        ],
      ),
    );
  }
}
