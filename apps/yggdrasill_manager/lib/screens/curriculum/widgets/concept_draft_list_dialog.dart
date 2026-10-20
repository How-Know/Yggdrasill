import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/concept_draft_models.dart';
import '../../../services/concept_draft_service.dart';
import '../../think/think_style.dart';
import 'concept_draft_batch_confirm.dart';
import 'concept_workspace.dart';

/// 개념 초안 목록. 고른 초안 id를 돌려준다. onConfirmed: 한 번에 확정해 라이브러리가 바뀌었을 때.
Future<String?> showConceptDraftListDialog(BuildContext context,
    {ConceptDraftService? service, VoidCallback? onConfirmed}) {
  return showDialog<String>(
    context: context,
    builder: (_) => ConceptDraftListDialog(service: service, onConfirmed: onConfirmed),
  );
}

class ConceptDraftListDialog extends StatefulWidget {
  const ConceptDraftListDialog({super.key, this.service, this.onConfirmed});

  final ConceptDraftService? service;
  final VoidCallback? onConfirmed;

  @override
  State<ConceptDraftListDialog> createState() => _ConceptDraftListDialogState();
}

class _ConceptDraftListDialogState extends State<ConceptDraftListDialog> {
  late final ConceptDraftService _svc = widget.service ?? ConceptDraftService();
  List<ConceptDraftSummary>? _rows;
  String? _error;
  bool _openOnly = true;

  /// 한 번에 확정할 초안. 검토를 저장한 검토 중 초안만 고를 수 있다.
  final Set<String> _selected = {};
  bool _busy = false;
  String? _progress;
  String? _notice;
  bool _noticeError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _rows = null;
      _error = null;
    });
    try {
      final rows = await _svc.listDrafts(openOnly: _openOnly);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _selected.retainWhere((id) => rows.any((d) => d.id == id && _selectable(d)));
      });
    } catch (e) {
      if (mounted) setState(() => _error = '초안 목록을 읽지 못했습니다: $e');
    }
  }

  /// 검토 중인 초안은 모두 고를 수 있다. 검토를 저장하지 않은 초안은 AI 초안 그대로 확정한다.
  static bool _selectable(ConceptDraftSummary d) => d.status == 'open';

  String _unitName(List<String> path) => path.isEmpty ? '(단원 없음)' : path.last;

  Future<void> _confirmSelected() async {
    final rows = _rows ?? const <ConceptDraftSummary>[];
    final ids = [
      for (final d in rows)
        if (_selected.contains(d.id)) d.id
    ];
    if (ids.isEmpty) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    DraftBatchOutcome? outcome;
    try {
      outcome = await confirmDraftBatch(
        context,
        service: _svc,
        ids: ids,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = '확정 전에 초안을 읽지 못했습니다: $e';
        _noticeError = true;
      });
      return;
    }
    if (!mounted) return;
    if (outcome == null) {
      setState(() => _busy = false);
      return;
    }
    if (outcome.done > 0) widget.onConfirmed?.call();
    setState(() {
      _busy = false;
      _selected.clear();
      _notice = outcome!.message;
      _noticeError = outcome.failed.isNotEmpty;
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final rows = _rows;
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        backgroundColor: kThinkBg,
        shape: thinkDialogShape,
        child: SizedBox(
          width: math.min(720, size.width - 48),
          height: math.min(620, size.height - 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
                child: Row(
                  children: [
                    const Icon(Icons.fact_check_outlined, color: kThinkAccent, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child:
                          Text('개념 초안', style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
                    ),
                    ThinkToggleChip(
                      label: '검토 중만',
                      icon: Icons.filter_alt_outlined,
                      selected: _openOnly,
                      enabled: !_busy,
                      onChanged: (v) {
                        setState(() => _openOnly = v);
                        unawaited(_load());
                      },
                    ),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20),
                      color: kThinkSub,
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: ConceptHint('"개념책 불러오기"에서 소단원마다 만든 초안입니다. 검토하고 확정할 때만 라이브러리에 들어갑니다. '
                    '앞 네모로 골라 한 번에 확정할 수 있습니다. 검토를 저장하지 않은 초안은 AI 초안 그대로 들어갑니다.'),
              ),
              const Divider(color: kThinkBorder, height: 1),
              Expanded(
                child: () {
                  if (_error != null) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
                          Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(onPressed: _load, child: const Text('다시 읽기'))),
                        ],
                      ),
                    );
                  }
                  if (rows == null) return const Center(child: CircularProgressIndicator(color: kThinkAccent));
                  if (rows.isEmpty) {
                    return Center(child: ConceptHint(_openOnly ? '검토 중인 초안이 없습니다.' : '만든 초안이 없습니다.'));
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, i) => _row(rows[i]),
                  );
                }(),
              ),
              _footer(rows ?? const []),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer(List<ConceptDraftSummary> rows) {
    final selectable = rows.where(_selectable).toList();
    if (selectable.isEmpty && _notice == null && _progress == null) return const SizedBox.shrink();
    final all = selectable.isNotEmpty && selectable.every((d) => _selected.contains(d.id));
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: kThinkBorder))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_notice != null) ...[
            ThinkNotice(
              text: _notice!,
              color: _noticeError ? kThinkError : kThinkSuccess,
              icon: _noticeError ? Icons.error_outline : Icons.check_circle_outline,
              onClose: _busy ? null : () => setState(() => _notice = null),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              if (selectable.isNotEmpty)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            if (all) {
                              _selected.clear();
                            } else {
                              _selected.addAll(selectable.map((d) => d.id));
                            }
                          }),
                  child: Text(all ? '모두 풀기' : '검토 중인 초안 모두 고르기', style: const TextStyle(color: kThinkLink)),
                ),
              Expanded(
                child: Text(
                  _progress ?? (_selected.isEmpty ? '' : '${_selected.length}개 고름'),
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkSub, fontSize: 13),
                ),
              ),
              if (_busy && _progress != null) ...[
                const SizedBox(width: 10),
                const SizedBox(
                    width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent)),
              ],
              const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed: _busy || _selected.isEmpty ? null : () => unawaited(_confirmSelected()),
                style: thinkPrimaryButton(),
                icon: const Icon(Icons.done_all, size: 18),
                label: Text(_selected.isEmpty ? '고른 초안 확정' : '고른 초안 ${_selected.length}개 확정'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(ConceptDraftSummary d) {
    final status = (
      conceptDraftStatusLabel(d.status),
      switch (d.status) {
        'confirmed' => kThinkSuccess,
        'discarded' || 'replaced' => kThinkHint,
        _ => kThinkAccent,
      },
    );
    final pages =
        d.pages.isEmpty ? '' : (d.pages.length == 1 ? '${d.pages.first}쪽' : '${d.pages.first}–${d.pages.last}쪽');
    final at = d.createdAt?.toLocal();
    final selectable = _selectable(d);
    final selected = _selected.contains(d.id);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _busy ? null : () => Navigator.pop(context, d.id),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kThinkPanel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? kThinkAccent.withValues(alpha: 0.6) : kThinkBorder),
          ),
          child: Row(
            children: [
              if (d.status == 'open') ...[
                Tooltip(
                  message: selected
                      ? '한 번에 확정할 초안에서 뺍니다.'
                      : (d.reviewSaved ? '한 번에 확정할 초안에 넣습니다(저장된 검토로).' : '한 번에 확정할 초안에 넣습니다(검토 없이 AI 초안 그대로).'),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: !selectable || _busy
                        ? null
                        : () => setState(() => selected ? _selected.remove(d.id) : _selected.add(d.id)),
                    child: Icon(
                      selected ? Icons.check_box : Icons.check_box_outline_blank,
                      size: 20,
                      color: selected ? kThinkAccent : (selectable ? kThinkSub : kThinkBorder),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_unitName(d.unitPath),
                        style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('${d.bookName} · ${d.gradeLabel} · ${d.unitPath.join(' > ')} · PDF $pages',
                        style: const TextStyle(color: kThinkSub, fontSize: 12), overflow: TextOverflow.ellipsis),
                    if (at != null)
                      ConceptHint('${at.year}-${_two(at.month)}-${_two(at.day)} ${_two(at.hour)}:${_two(at.minute)} 만듦'
                          '${d.reviewSaved ? ' · 검토 저장함' : ''}'),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ThinkBadge('개념 ${d.conceptCount}'),
              const SizedBox(width: 6),
              if (!d.hasFolderPlan) ...[const ThinkBadge('폴더 제안 없음', color: kThinkHint), const SizedBox(width: 6)],
              ThinkBadge(status.$1, color: status.$2),
            ],
          ),
        ),
      ),
    );
  }

  String _two(int n) => n.toString().padLeft(2, '0');
}
