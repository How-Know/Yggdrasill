import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/textbook_problem_review_service.dart';
import '../problem_bank/widgets/problem_bank_question_card.dart';

const Color _kPanelBg = Color(0xFF1C1C1E);
const Color _kFieldBg = Color(0xFF2C2C2E);
const Color _kBorder = Color(0x22FFFFFF);
const Color _kText = Color(0xFFEAF2F2);
const Color _kTextSub = Color(0xFF9FB3B3);
const Color _kTextMuted = Color(0xFF6E7E7E);
const Color _kAccent = Color(0xFF33A373);
const Color _kBlue = Color(0xFF64B5F6);
const Color _kError = Color(0xFFE57373);
const Color _kWarn = Color(0xFFE0B35A);
const double _kPanelRadius = 28;
const double _kInnerRadius = 18;
const int _kRenderCheckChunk = 5;

/// 렌더 엔진 문제로 보류한 문항을 교재·단원에 걸쳐 한 곳에서 본다.
/// 엔진(게이트웨이 xelatex 템플릿)을 고친 뒤 "전체 다시 렌더링"으로 같은 문항을 새로 찍어 비교하고,
/// 해결된 것은 승인해서 품질 집계로 돌려보낸다.
class TextbookReviewEngineHoldPanel extends StatefulWidget {
  const TextbookReviewEngineHoldPanel({super.key, required this.service});

  final TextbookProblemReviewService service;

  @override
  State<TextbookReviewEngineHoldPanel> createState() => _TextbookReviewEngineHoldPanelState();
}

class _TextbookReviewEngineHoldPanelState extends State<TextbookReviewEngineHoldPanel> {
  TextbookProblemReviewService get _svc => widget.service;

  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _notice;
  String? _progress;
  List<TextbookReviewEngineHoldEntry> _entries = const [];

  /// 문항 카드(V2) 서명 URL. 키 cropId
  final Map<String, String> _problemUrls = {};

  /// 정답+해설 카드 URL. 키 cropId
  final Map<String, String> _solutionUrls = {};
  final Set<String> _rendering = {};
  final Map<String, String> _renderErrors = {};

  /// 다시 렌더링할 때마다 올려 Image.network 캐시를 피한다.
  int _renderGeneration = 0;
  bool _showResolved = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load(renderAll: true));
  }

  List<TextbookReviewEngineHoldEntry> get _held => [for (final e in _entries) if (!e.resolved) e];
  List<TextbookReviewEngineHoldEntry> get _resolved => [for (final e in _entries) if (e.resolved) e];

  Future<void> _load({bool renderAll = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _svc.fetchEngineHoldEntries();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      if (renderAll) await _renderEntries(_held, fresh: false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '엔진 보류 목록을 읽지 못했습니다: $e';
      });
    }
  }

  /// 문항 카드와 정답+해설 카드를 V2 로 찍는다. fresh=true 면 있던 URL을 버리고 새로 찍는다(엔진 수정 후 비교용).
  Future<void> _renderEntries(List<TextbookReviewEngineHoldEntry> entries, {required bool fresh}) async {
    if (entries.isEmpty || !_svc.hasGateway) return;
    setState(() {
      _busy = true;
      if (fresh) {
        _renderGeneration += 1;
        for (final e in entries) {
          _problemUrls.remove(e.item.cropId);
          _solutionUrls.remove(e.item.cropId);
          _renderErrors.remove(e.item.cropId);
        }
      }
      _progress = 'V2 카드 다시 찍는 중 (${entries.length}문항)...';
    });
    try {
      // 문항 카드: 학원별로 묶어 batch-render
      final byAcademy = <String, List<TextbookReviewEngineHoldEntry>>{};
      for (final e in entries) {
        if (!fresh && _problemUrls.containsKey(e.item.cropId)) continue;
        byAcademy.putIfAbsent(e.scope.academyId, () => []).add(e);
      }
      for (final g in byAcademy.entries) {
        try {
          final urls = await _svc.fetchEnginePreviewUrls(academyId: g.key, items: [for (final e in g.value) e.item]);
          if (!mounted) return;
          setState(() => _problemUrls.addAll(urls));
        } catch (e) {
          for (final x in g.value) {
            _renderErrors[x.item.cropId] = '$e';
          }
        }
      }
      // 정답+해설 카드: 문항마다
      for (var i = 0; i < entries.length; i += 1) {
        final e = entries[i];
        final it = e.item;
        if (!fresh && _solutionUrls.containsKey(it.cropId)) continue;
        if (it.primarySolutionText.isEmpty && it.displayAnswer.isEmpty) continue;
        if (!mounted) return;
        setState(() {
          _rendering.add(it.cropId);
          _progress = 'V2 카드 다시 찍는 중 ${i + 1} / ${entries.length} — ${e.scope.midName} ${it.problemNumber}번';
        });
        try {
          final url = await _svc.renderAnswerSolutionCard(
            academyId: e.scope.academyId,
            item: it,
            solutionText: it.primarySolutionText,
            solutionKind: it.primarySolutionKind,
          );
          if (url.isNotEmpty) _solutionUrls[it.cropId] = url;
        } catch (err) {
          _renderErrors[it.cropId] = '$err';
        } finally {
          _rendering.remove(it.cropId);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          if (fresh) _notice = '${entries.length}문항을 현재 엔진으로 다시 렌더링했습니다. 보류 시점 판정과 비교해 보세요.';
        });
      }
    }
  }

  /// 다시 찍은 카드로 AI 학생 시점 렌더 검수를 다시 돌린다(보류 상태는 유지되고 render_checks 만 갱신).
  Future<void> _recheck(List<TextbookReviewEngineHoldEntry> entries) async {
    if (entries.isEmpty) return;
    setState(() => _busy = true);
    var checked = 0;
    try {
      for (var i = 0; i < entries.length; i += _kRenderCheckChunk) {
        final chunk = entries.skip(i).take(_kRenderCheckChunk).toList();
        final byAcademy = <String, List<Map<String, dynamic>>>{};
        for (final e in chunk) {
          final p = _problemUrls[e.item.cropId];
          final s = _solutionUrls[e.item.cropId];
          if ((p ?? '').isEmpty && (s ?? '').isEmpty) continue;
          byAcademy.putIfAbsent(e.scope.academyId, () => []).add({
            'crop_id': e.item.cropId,
            if ((p ?? '').isNotEmpty) 'problem_url': p,
            if ((s ?? '').isNotEmpty) 'answer_solution_url': s,
            'solution_kind': e.item.primarySolutionKind,
            'has_solution_figures': e.item.solutionFigureAssets.isNotEmpty,
          });
        }
        if (!mounted) return;
        setState(() => _progress = 'AI 렌더 재검수 ${i + 1}~${i + chunk.length} / ${entries.length}...');
        for (final g in byAcademy.entries) {
          final res = await _svc.runRenderCheck(academyId: g.key, items: g.value);
          checked += (res['processed'] as num?)?.toInt() ?? 0;
        }
      }
      if (!mounted) return;
      setState(() => _notice = 'AI 렌더 재검수를 $checked문항에 했습니다. 정상으로 바뀐 문항은 "해결됨 → 승인"으로 돌려보내세요.');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _notice = 'AI 렌더 재검수 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _approve(List<TextbookReviewEngineHoldEntry> entries) async {
    if (entries.isEmpty) return;
    setState(() => _busy = true);
    try {
      final n = await _svc.approveAxis([for (final e in entries) e.item.cropId], 'quality');
      if (!mounted) return;
      setState(() => _notice = '$n문항을 해결됨으로 승인했습니다(품질 집계로 돌아감).');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _notice = '승인 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _release(TextbookReviewEngineHoldEntry e) async {
    setState(() => _busy = true);
    try {
      await _svc.setEngineHold([e.item.cropId], hold: false);
      if (!mounted) return;
      setState(() => _notice = '${e.scope.midName} ${e.item.problemNumber}번 보류를 해제했습니다(오류 상태로 돌아감).');
      await _load();
    } catch (err) {
      if (mounted) setState(() => _notice = '보류 해제 실패: $err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 재검수가 보류 시점 이후에 있었고 이상이 없으면 "해결 후보"
  bool _looksFixed(TextbookProblemReviewItem it) =>
      it.renderCheckedAt != null && it.engineHeldAt != null && it.renderCheckedAt!.isAfter(it.engineHeldAt!) && !it.renderHasIssue;

  Map<String, int> get _symptomCounts {
    final out = <String, int>{};
    for (final e in _held) {
      final k = e.item.engineSymptom.isNotEmpty ? e.item.engineSymptom : (e.item.engineHoldNote ?? '분류 없음');
      out[k] = (out[k] ?? 0) + 1;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final held = _held;
    final resolved = _resolved;
    final fixedCandidates = [for (final e in held) if (_looksFixed(e.item)) e];
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: (size.width - 48).clamp(600.0, 1320.0),
        height: size.height - 48,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _kPanelBg,
          borderRadius: BorderRadius.circular(_kPanelRadius),
          border: Border.all(color: _kBorder, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.build_circle_outlined, color: _kWarn, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '렌더 엔진 오류 목록 — 보류 ${held.length}문항${resolved.isNotEmpty ? ' · 최근 해결 ${resolved.length}' : ''}',
                        style: const TextStyle(color: _kText, fontSize: 17, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        '엔진(게이트웨이 템플릿)을 고친 뒤 "전체 다시 렌더링"으로 같은 문항을 새로 찍어 비교하고, 해결된 것은 승인합니다. 승인한 문항은 품질 집계의 완료로 돌아갑니다.',
                        style: TextStyle(color: _kTextSub, fontSize: 12.5, height: 1.35),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '닫기',
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: _kTextSub),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _busy || held.isEmpty || !_svc.hasGateway ? null : () => unawaited(_renderEntries(held, fresh: true)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('전체 다시 렌더링 (현재 엔진)'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy || held.isEmpty || !_svc.hasGateway ? null : () => unawaited(_recheck(held)),
                  style: _outline(_kBlue),
                  icon: const Icon(Icons.rule_rounded, size: 18, color: _kBlue),
                  label: const Text('AI 렌더 재검수 (보류 전체)'),
                ),
                if (fixedCandidates.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => unawaited(_approve(fixedCandidates)),
                    style: _outline(_kAccent),
                    icon: const Icon(Icons.done_all_rounded, size: 18, color: _kAccent),
                    label: Text('재검수 정상 ${fixedCandidates.length}문항 일괄 승인'),
                  ),
                TextButton.icon(
                  onPressed: () => setState(() => _showResolved = !_showResolved),
                  icon: Icon(_showResolved ? Icons.visibility_off_outlined : Icons.history_rounded, size: 16, color: _kTextSub),
                  label: Text(_showResolved ? '해결 내역 숨기기' : '최근 해결 내역 보기 (${resolved.length})', style: const TextStyle(color: _kTextSub)),
                ),
                IconButton(
                  tooltip: '목록 새로고침',
                  onPressed: _busy ? null : () => unawaited(_load()),
                  icon: const Icon(Icons.sync_rounded, color: _kTextSub, size: 20),
                ),
              ],
            ),
            if (_symptomCounts.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 4, top: 4),
                    child: Text('증상별', style: TextStyle(color: _kTextSub, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  for (final s in _symptomCounts.entries) _pill('${s.key} ×${s.value}', _kWarn),
                ],
              ),
            ],
            if (_progress != null) ...[
              const SizedBox(height: 10),
              _banner(_progress!, _kAccent, Icons.autorenew_rounded),
            ],
            if (_notice != null) ...[
              const SizedBox(height: 10),
              _banner(_notice!, _kAccent, Icons.info_outline_rounded),
            ],
            if (!_svc.hasGateway) ...[
              const SizedBox(height: 10),
              _banner('게이트웨이가 연결되지 않아 V2 카드를 찍을 수 없습니다. 목록과 보류 시점 판정만 표시합니다.', _kWarn, Icons.cloud_off_rounded),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: _kAccent))
                  : _error != null
                      ? Center(child: Text(_error!, style: const TextStyle(color: _kError, fontSize: 14)))
                      : held.isEmpty && (!_showResolved || resolved.isEmpty)
                          ? const Center(
                              child: Text(
                                '엔진 문제로 보류한 문항이 없습니다. 문항검수에서 "엔진 문제로 보류"를 누르면 여기에 모입니다.',
                                style: TextStyle(color: _kTextSub, fontSize: 14, fontWeight: FontWeight.w600),
                                textAlign: TextAlign.center,
                              ),
                            )
                          : ListView(
                              children: [
                                for (final e in held) _entryTile(e),
                                if (_showResolved && resolved.isNotEmpty) ...[
                                  const Padding(
                                    padding: EdgeInsets.fromLTRB(4, 16, 4, 8),
                                    child: Text('최근 30일 내 해결(승인)된 문항', style: TextStyle(color: _kTextSub, fontSize: 13, fontWeight: FontWeight.w800)),
                                  ),
                                  for (final e in resolved) _entryTile(e),
                                ],
                              ],
                            ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(TextbookReviewEngineHoldEntry e) {
    final it = e.item;
    final snap = it.engineHoldSnapshot;
    final snapRc = snap['render_checks'] is Map ? Map<String, dynamic>.from(snap['render_checks'] as Map) : const <String, dynamic>{};
    final snapQc = snap['quality_checks'] is Map ? Map<String, dynamic>.from(snap['quality_checks'] as Map) : const <String, dynamic>{};
    final heldIssue = '${snapRc['issue_title'] ?? snapQc['issue_title'] ?? it.engineHoldNote ?? ''}'.trim();
    final heldDetail = '${snapRc['issue_detail'] ?? snapQc['issue_detail'] ?? ''}'.trim();
    final recheckedAfterHold = it.renderCheckedAt != null && it.engineHeldAt != null && it.renderCheckedAt!.isAfter(it.engineHeldAt!);
    final fixed = _looksFixed(it);
    final problemUrl = _problemUrls[it.cropId];
    final solutionUrl = _solutionUrls[it.cropId];
    final rendering = _rendering.contains(it.cropId) || (_busy && problemUrl == null && _progress != null);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kFieldBg,
        borderRadius: BorderRadius.circular(_kInnerRadius),
        border: Border.all(
          color: e.resolved ? _kBorder : (fixed ? _kAccent.withValues(alpha: 0.7) : _kWarn.withValues(alpha: 0.6)),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${e.scope.bookTitle} · ${e.scope.bigOrder}.${e.scope.midOrder} ${e.scope.midName} · ${it.problemNumber}번',
                style: const TextStyle(color: _kText, fontSize: 13.5, fontWeight: FontWeight.w800),
              ),
              if (e.resolved)
                _pill('해결됨${it.engineResolvedAt != null ? ' ${_fmt(it.engineResolvedAt!)}' : ''}', _kAccent)
              else ...[
                _pill('보류${it.engineHeldAt != null ? ' ${_fmt(it.engineHeldAt!)}' : ''}', _kWarn),
                if (it.engineSymptom.isNotEmpty) _pill(it.engineSymptom, _kWarn),
                if (recheckedAfterHold) _pill(fixed ? '재검수 정상 → 승인 가능' : '재검수에서도 이상', fixed ? _kAccent : _kError),
              ],
              if (it.pbQuestionId.isEmpty) _pill('문제은행 사본 없음', _kTextMuted),
            ],
          ),
          if (heldIssue.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '보류 시점 판정: $heldIssue${heldDetail.isNotEmpty ? ' — $heldDetail' : ''}',
              style: const TextStyle(color: _kTextSub, fontSize: 12, height: 1.35),
            ),
          ],
          if (recheckedAfterHold && it.renderChecks['issue_title'] != null) ...[
            const SizedBox(height: 4),
            Text(
              '최근 재검수: ${it.renderChecks['issue_title']} — ${it.renderChecks['issue_detail'] ?? ''}',
              style: TextStyle(color: fixed ? _kAccent : _kError, fontSize: 12, height: 1.35),
            ),
          ],
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, c) {
              final cards = [
                _card('문항 카드 (V2 · 현재 엔진)', problemUrl, rendering, _renderErrors[it.cropId]),
                _card('정답 + ${it.primarySolutionKind == 'ai' ? 'AI 풀이' : '원본 해설'} (V2 · 현재 엔진)', solutionUrl, rendering, null),
              ];
              if (c.maxWidth < 760) {
                return Column(children: [cards[0], const SizedBox(height: 8), cards[1]]);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Expanded(child: cards[0]), const SizedBox(width: 10), Expanded(child: cards[1])],
              );
            },
          ),
          if (!e.resolved) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy || !_svc.hasGateway ? null : () => unawaited(_renderEntries([e], fresh: true)),
                  style: _outline(_kBlue),
                  icon: const Icon(Icons.refresh_rounded, size: 16, color: _kBlue),
                  label: const Text('다시 렌더링'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy || !_svc.hasGateway ? null : () => unawaited(_recheck([e])),
                  style: _outline(_kBlue),
                  icon: const Icon(Icons.rule_rounded, size: 16, color: _kBlue),
                  label: const Text('AI 렌더 재검수'),
                ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_approve([e])),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: fixed ? _kAccent : _kFieldBg,
                    foregroundColor: fixed ? Colors.white : _kText,
                    side: fixed ? null : const BorderSide(color: _kBorder, width: 0.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  ),
                  icon: const Icon(Icons.task_alt_rounded, size: 16),
                  label: const Text('해결됨 → 품질 승인'),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : () => unawaited(_release(e)),
                  icon: const Icon(Icons.undo_rounded, size: 16, color: _kTextSub),
                  label: const Text('보류 해제 (오류로 되돌림)', style: TextStyle(color: _kTextSub)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _card(String title, String? url, bool loading, String? error) {
    final hasUrl = (url ?? '').isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: _kTextSub, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        ProblemBankQuestionCard(
          radius: _kInnerRadius,
          backgroundColor: Colors.white,
          borderColor: const Color(0xFFD5DDDD),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 96),
            child: hasUrl
                ? Image.network(
                    url!,
                    key: ValueKey('$url#$_renderGeneration'),
                    fit: BoxFit.fitWidth,
                    alignment: Alignment.topCenter,
                    loadingBuilder: (_, child, p) => p == null
                        ? child
                        : const SizedBox(height: 96, child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent))),
                    errorBuilder: (_, __, ___) => const SizedBox(
                      height: 96,
                      child: Center(child: Text('V2 카드 이미지를 불러오지 못했습니다.', style: TextStyle(color: Color(0xFF9A3B3B), fontSize: 12))),
                    ),
                  )
                : SizedBox(
                    height: 96,
                    child: Center(
                      child: loading
                          ? const CircularProgressIndicator(strokeWidth: 2, color: _kAccent)
                          : Text(
                              error != null ? 'V2 렌더 실패: $error' : (_svc.hasGateway ? '아직 찍지 않았습니다.' : '게이트웨이 미연결'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xFF6B7A7A), fontSize: 12),
                            ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  static String _fmt(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.month}/${l.day} ${two(l.hour)}:${two(l.minute)}';
  }

  ButtonStyle _outline(Color color) => OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.6), width: 0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      );

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
      );

  Widget _banner(String text, Color color, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(_kInnerRadius),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(color: _kText, fontSize: 13, height: 1.35))),
          ],
        ),
      );
}
