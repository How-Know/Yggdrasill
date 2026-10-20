import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/concept_draft_models.dart';
import '../../../services/concept_draft_service.dart';
import '../../think/think_style.dart';

class DraftBatchOutcome {
  const DraftBatchOutcome({required this.confirmedIds, required this.asIs, required this.failed});

  final List<String> confirmedIds;

  int get done => confirmedIds.length;

  /// 확정한 초안 중 검토 없이 AI 초안 그대로 넣은 수.
  final int asIs;
  final List<String> failed;

  String get message => [
        '초안 $done개를 확정해 라이브러리에 넣었습니다${asIs > 0 ? '(그중 $asIs개는 AI 초안 그대로)' : ''}.',
        if (failed.isNotEmpty) '확정하지 못한 초안 ${failed.length}개(검토 화면에서 열어 확인하세요):\n${failed.join('\n')}',
      ].join('\n');
}

String _unitName(List<String> path) => path.isEmpty ? '(단원 없음)' : path.last;

/// 고른 초안을 확인 창을 거쳐 차례로 확정한다. 검토를 저장하지 않은 초안은 AI 초안·폴더 제안 그대로 검토를 저장한 뒤 확정한다.
/// 초안마다 따로 확정하므로 하나가 실패해도 앞서 확정한 것은 남는다. 취소했거나 확정할 것이 없으면 null.
/// 초안·유형·폴더를 읽지 못하면 그 오류를 그대로 던진다.
Future<DraftBatchOutcome?> confirmDraftBatch(
  BuildContext context, {
  required ConceptDraftService service,
  required List<String> ids,
  required ValueChanged<String?> onProgress,
}) async {
  if (ids.isEmpty) return null;
  onProgress('초안을 확인하는 중');
  final DraftBatchPlan plan;
  try {
    final types = await service.conceptTypes();
    final paths = await service.libraryFolderPaths();
    final records = <ConceptDraftRecord>[];
    for (final id in ids) {
      records.add(await service.fetchDraft(id));
    }
    final kept = [
      for (final r in records)
        for (final it in (r.reviewSavedAt != null && r.review.isNotEmpty ? r.review : initialReview(r)))
          if (it.kept) it,
    ];
    Set<String>? names;
    try {
      names = (await service.libraryConceptsNamed([for (final it in kept) it.title])).keys.toSet();
    } catch (_) {
      names = null;
    }
    final ready = kept.any((it) => it.relation != null) ? await service.relationsReady() : true;
    plan = planDraftBatchConfirm(records,
        libraryPaths: paths,
        types: types,
        libraryNames: names,
        relationsBlocked: ready ? null : kConceptRelationsNotReady);
  } finally {
    onProgress(null);
  }
  if (!context.mounted) return null;
  final ok = await _askBatch(context, plan);
  if (!ok || plan.ready.isEmpty || !context.mounted) return null;
  final failed = <String>[];
  final confirmed = <String>[];
  var asIs = 0;
  for (var i = 0; i < plan.ready.length; i += 1) {
    final r = plan.ready[i];
    final draft = plan.asIs[r.id];
    onProgress('확정하는 중 (${i + 1}/${plan.ready.length}) ${_unitName(r.unitPath)}');
    try {
      final savedAt = draft == null
          ? r.reviewSavedAt!
          : await service.saveReview(r.id, draft.items, r.reviewSavedAt, newTypes: draft.newTypes);
      await service.confirm(r.id, savedAt);
      confirmed.add(r.id);
      if (draft != null) asIs += 1;
    } catch (e) {
      failed.add('· ${_unitName(r.unitPath)}: ${e is ConceptDraftException ? e.message : e}');
    }
    if (!context.mounted) break;
  }
  onProgress(null);
  return DraftBatchOutcome(confirmedIds: confirmed, asIs: asIs, failed: failed);
}

Future<bool> _askBatch(BuildContext context, DraftBatchPlan plan) async {
  final size = MediaQuery.sizeOf(context);
  Widget section(String title, List<String> lines, {Color color = kThinkSub}) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            for (final l in lines) Text(l, style: TextStyle(color: color, fontSize: 13, height: 1.5)),
          ],
        ),
      );
  final asIs = [
    for (final r in plan.ready)
      if (plan.asIs.containsKey(r.id)) r
  ];
  final relationText = plan.ready.isEmpty ? null : reviewRelationSentence(plan.relationTotal);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(plan.ready.isEmpty ? '확정할 수 있는 초안이 없습니다' : '초안 ${plan.ready.length}개를 라이브러리에 넣을까요?',
          style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: math.max(200, size.height - 260)),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (plan.ready.isNotEmpty) ...[
                Text(
                    '개념 ${plan.conceptCount}개를 넣습니다. 검토를 저장한 초안은 저장된 검토로, 저장하지 않은 초안은 AI 초안·폴더 제안 그대로 넣습니다. '
                    '초안마다 차례로 확정하고, 하나가 실패해도 앞서 확정한 초안은 남습니다.',
                    style: const TextStyle(color: kThinkSub, height: 1.5)),
                section('확정할 초안', [
                  for (final r in plan.ready)
                    '· ${_unitName(r.unitPath)} — 개념 ${plan.reviewOf(r).where((it) => it.kept).length}개'
                        '${(plan.relations[r.id]?.count(ReviewRelationKind.statement) ?? 0) > 0 ? '(다른 서술 ${plan.relations[r.id]!.count(ReviewRelationKind.statement)}개)' : ''}'
                        '${plan.asIs.containsKey(r.id) ? ' · AI 초안 그대로' : ''}',
                ]),
                if (asIs.isNotEmpty)
                  section(
                    '검토 없이 넣는 초안 ${asIs.length}개',
                    ['AI가 만든 이름·내용·유형·폴더·주제 묶음 그대로 검토로 저장한 뒤 확정합니다. 넣은 뒤에는 라이브러리에서 고칩니다.'],
                    color: kThinkAccent,
                  ),
              ],
              if (plan.blocked.isNotEmpty)
                section(
                  '확정하지 않는 초안 ${plan.blocked.length}개',
                  [for (final b in plan.blocked) '· ${_unitName(b.record.unitPath)} — ${b.reason}'],
                  color: kThinkError,
                ),
              if (plan.ready.isNotEmpty)
                section(
                  plan.newFolders.isEmpty
                      ? '새로 만드는 폴더 없음'
                      : '새로 만드는 폴더 ${plan.newFolders.length}개(이름이 비슷한 폴더가 없는지 확인하세요)',
                  [for (final f in plan.newFolders) '· $f'],
                ),
              if (plan.newTypes.isNotEmpty)
                section('유형 목록에 더하는 새 유형 ${plan.newTypes.length}개', [for (final t in plan.newTypes) '· $t']),
              if (plan.sameTitles.isNotEmpty)
                section(
                  '여러 초안에 같은 이름으로 있는 개념 ${plan.sameTitles.length}개(같은 이름의 다른 판으로 들어가고, 관계를 정하지 않았으면 뒤에 넣는 쪽이 "검토 필요"로 표시됩니다)',
                  [for (final t in plan.sameTitles) '· ${t.title} — 초안 ${t.drafts}개'],
                  color: kThinkAccent,
                ),
              if (plan.overlaps.isNotEmpty)
                section(
                  'Think가 겹칠 수 있다고 본 개념 ${plan.overlaps.length}개(지우지 않았습니다)',
                  [for (final o in plan.overlaps) '· ${o.unit} — ${o.title}: ${o.other}'],
                  color: kThinkAccent,
                ),
              if (relationText != null)
                KeyedSubtree(
                  key: const ValueKey('batch-relations'),
                  child: section('기존 개념과의 관계', relationText.split('\n'), color: kThinkAccent),
                ),
              if (plan.ready.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('같은 이름의 폴더·유형이 이미 있으면 그것을 씁니다. 기존 개념의 확정 내용·본문·폴더는 바꾸지 않습니다.',
                      style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.5)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(plan.ready.isEmpty ? '닫기' : '취소', style: const TextStyle(color: kThinkSub)),
        ),
        if (plan.ready.isNotEmpty)
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: thinkPrimaryButton(),
            child: Text('${plan.ready.length}개 확정'),
          ),
      ],
    ),
  );
  return ok == true;
}
