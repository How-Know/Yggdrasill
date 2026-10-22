import 'concept_draft_models.dart';

/// 새 교재 항목과 비교할 기존 개념(concept_compare_targets). 읽기 전용이다.
class ConceptCompareTarget {
  const ConceptCompareTarget({
    required this.id,
    required this.name,
    required this.folder,
    required this.content,
    required this.statements,
    required this.sources,
    required this.books,
    required this.contentDraft,
  });

  factory ConceptCompareTarget.fromJson(Map<String, dynamic> m) => ConceptCompareTarget(
        id: '${m['id'] ?? ''}',
        name: '${m['name'] ?? ''}',
        folder: [for (final s in (m['folder'] as List?) ?? const []) '$s'],
        content: '${m['content'] ?? ''}',
        statements: [
          for (final s in (m['statements'] as List?) ?? const [])
            if (s is Map)
              ConceptCompareStatement(
                id: '${s['id'] ?? ''}',
                confirmed: s['confirmed'] == true,
                text: '${s['text'] ?? ''}',
              ),
        ],
        sources: (m['sources'] as num?)?.toInt() ?? 0,
        books: [for (final s in (m['books'] as List?) ?? const []) '$s'],
        contentDraft: m['content_draft'] == true,
      );

  final String id;
  final String name;
  final List<String> folder;

  /// 기본 서술(개념 본문).
  final String content;
  final List<ConceptCompareStatement> statements;

  /// 이어진 출처 줄 수와 그 책 이름.
  final int sources;
  final List<String> books;

  /// 기본 서술 수정안이 이미 있는지. 있으면 "대표 서술 수정안"으로 확정할 수 없다.
  final bool contentDraft;

  ConceptCompareStatement? statement(String? id) {
    for (final s in statements) {
      if (s.id == id) return s;
    }
    return null;
  }
}

class ConceptCompareStatement {
  const ConceptCompareStatement({required this.id, required this.confirmed, required this.text});

  final String id;
  final bool confirmed;
  final String text;

  /// 고르기 목록에 쓰는 짧은 이름(첫 줄).
  String get label {
    final first = text.trim().split('\n').first.trim();
    final short = first.length > 40 ? '${first.substring(0, 40)}…' : first;
    return '${short.isEmpty ? '(제목 없음)' : short}${confirmed ? '' : ' (확정 전)'}';
  }
}

/// AI 비교 제안의 한 줄. 운영자가 "반영"을 누르면 그 항목의 관계(저장 전)로 들어간다.
class ConceptCompareSuggestion {
  const ConceptCompareSuggestion({
    required this.key,
    required this.kind,
    required this.conceptId,
    required this.conceptName,
    required this.statementId,
    required this.reason,
    required this.differences,
    required this.draftExists,
  });

  static ConceptCompareSuggestion? fromJson(Map<String, dynamic> m) {
    final kind = ReviewRelationKind.fromDb(m['choice']);
    final key = '${m['key'] ?? ''}'.trim();
    if (kind == null || key.isEmpty) return null;
    final id = '${m['concept_id'] ?? ''}'.trim();
    if (kind.needsTarget && id.isEmpty) return null;
    final st = '${m['statement_id'] ?? ''}'.trim();
    return ConceptCompareSuggestion(
      key: key,
      kind: kind,
      conceptId: id.isEmpty ? null : id,
      conceptName: '${m['concept_name'] ?? ''}'.trim().isEmpty ? null : '${m['concept_name']}'.trim(),
      statementId: st.isEmpty ? null : st,
      reason: '${m['reason'] ?? ''}'.trim(),
      differences: '${m['differences'] ?? ''}'.trim(),
      draftExists: m['draft_exists'] == true,
    );
  }

  final String key;
  final ReviewRelationKind kind;
  final String? conceptId;
  final String? conceptName;
  final String? statementId;
  final String reason;
  final String differences;

  /// 수정안 제안인데 그 개념에 이미 수정안이 있다.
  final bool draftExists;

  /// 반영할 수 있는지. 수정안이 이미 있는 개념의 수정안 제안은 반영하지 않는다(확정이 막힌다).
  bool get applicable => !(kind == ReviewRelationKind.revise && draftExists);

  ReviewRelation relation({String? statementLabel}) => ReviewRelation(
        kind: kind,
        conceptId: kind.takesTarget ? conceptId : null,
        conceptName: kind.takesTarget ? conceptName : null,
        statementId: kind == ReviewRelationKind.source ? statementId : null,
        statementLabel: kind == ReviewRelationKind.source && statementId != null ? statementLabel : null,
      );

  /// 지금 관계가 이미 이 제안과 같은지.
  bool sameAs(ReviewRelation? r) =>
      r != null &&
      r.kind == kind &&
      r.conceptId == (kind.takesTarget ? conceptId : null) &&
      r.statementId == (kind == ReviewRelationKind.source ? statementId : null);
}

class ConceptCompareProposal {
  const ConceptCompareProposal({
    required this.summary,
    required this.items,
    required this.noCandidates,
    required this.overLimit,
    required this.unanswered,
  });

  factory ConceptCompareProposal.fromJson(Map<String, dynamic> m) {
    final checks = m['checks'] is Map ? Map<String, dynamic>.from(m['checks'] as Map) : const <String, dynamic>{};
    List<String> keys(Object? v) => [for (final s in (v as List?) ?? const []) '$s'];
    final items = <String, ConceptCompareSuggestion>{};
    for (final v in (m['items'] as List?) ?? const []) {
      if (v is! Map) continue;
      final s = ConceptCompareSuggestion.fromJson(Map<String, dynamic>.from(v));
      if (s != null) items.putIfAbsent(s.key, () => s);
    }
    return ConceptCompareProposal(
      summary: '${m['summary'] ?? ''}'.trim(),
      items: items,
      noCandidates: keys(checks['no_candidates']),
      overLimit: keys(checks['over_limit']),
      unanswered: keys(checks['unanswered']),
    );
  }

  final String summary;

  /// 항목 key → 제안.
  final Map<String, ConceptCompareSuggestion> items;
  final List<String> noCandidates;
  final List<String> overLimit;
  final List<String> unanswered;

  ConceptCompareProposal without(String key) => ConceptCompareProposal(
        summary: summary,
        items: {...items}..remove(key),
        noCandidates: noCandidates,
        overLimit: overLimit,
        unanswered: unanswered,
      );

  /// 제안을 받은 뒤 화면에 알릴 한 줄.
  String get notice {
    final parts = <String>[
      if (summary.isNotEmpty) summary,
      '제안 ${items.length}개(반영하기 전에는 검토가 바뀌지 않습니다).',
      if (noCandidates.isNotEmpty) '비교할 기존 개념이 없어 보내지 않은 항목 ${noCandidates.length}개.',
      if (overLimit.isNotEmpty) '한 번에 12개까지라 이번에 보내지 않은 항목 ${overLimit.length}개.',
      if (unanswered.isNotEmpty) 'AI가 답하지 않은 항목 ${unanswered.length}개.',
    ];
    return parts.join(' ');
  }
}

/// 보류한 검토 항목(concept_draft_holds_open).
class ConceptDraftHold {
  const ConceptDraftHold({
    required this.id,
    required this.draftId,
    required this.itemKey,
    required this.title,
    required this.content,
    required this.reopenedBefore,
    required this.createdAt,
    required this.bookName,
    required this.gradeLabel,
    required this.unitPath,
  });

  factory ConceptDraftHold.fromJson(Map<String, dynamic> m) => ConceptDraftHold(
        id: '${m['id'] ?? ''}',
        draftId: '${m['draft_id'] ?? ''}',
        itemKey: '${m['item_key'] ?? ''}',
        title: '${m['title'] ?? ''}',
        content: '${m['content'] ?? ''}',
        reopenedBefore: m['status'] == 'reopened',
        createdAt: DateTime.tryParse('${m['created_at'] ?? ''}'),
        bookName: '${m['book_name'] ?? ''}',
        gradeLabel: '${m['grade_label'] ?? ''}',
        unitPath: [for (final s in (m['unit_path'] as List?) ?? const []) '$s'],
      );

  final String id;
  final String draftId;
  final String itemKey;
  final String title;
  final String content;

  /// 다시 검토하려고 연 초안을 버려 목록으로 돌아온 항목.
  final bool reopenedBefore;
  final DateTime? createdAt;
  final String bookName;
  final String gradeLabel;
  final List<String> unitPath;
}

/// 보류 항목을 초안 기록별로 묶는다(다시 검토는 초안 기록 하나 단위). 최근 것부터.
List<List<ConceptDraftHold>> groupHoldsByDraft(List<ConceptDraftHold> holds) {
  final out = <String, List<ConceptDraftHold>>{};
  for (final h in holds) {
    (out[h.draftId] ??= []).add(h);
  }
  return out.values.toList();
}
