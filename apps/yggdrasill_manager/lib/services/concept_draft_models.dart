import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'concept_book_service.dart';

/// 개념책 소단원 → 개념 초안(concept_drafts) 화면 모델과 계산. 서버 기록을 그대로 읽고 추정하지 않는다.
/// 설계: docs/architecture/concept-library.md §7

const String kConceptPagePromptVersion = 'concept_page_read.v1';

/// 한 번에 초안으로 만들 수 있는 소단원 쪽 수(Edge `MAX_PAGES`·DB `concept_drafts_pages_check`와 같다).
const int kConceptDraftMaxPages = 20;

/// 비용 안내용 대략값(시범 실측, 미국 달러). 쪽 읽기 한 번, 정리+폴더 제안 한 번.
const double kConceptDraftCostPerRead = 0.018;
const double kConceptDraftCostPerDraft = 0.09;

// ───────── 문항 가림 ─────────

class ConceptPageMask {
  const ConceptPageMask({required this.label, required this.bbox1k, this.problemNumber});

  final String label;

  /// [ymin, xmin, ymax, xmax], 0~1000.
  final List<int> bbox1k;
  final String? problemNumber;

  Map<String, dynamic> toJson() => {
        'label': label,
        'bbox_1k': bbox1k,
        if (problemNumber != null) 'problem_number': problemNumber,
      };
}

List<int>? _box(dynamic v) {
  if (v is! List || v.length != 4) return null;
  final n = <int>[];
  for (final x in v) {
    final d = x is num ? x.toDouble() : double.tryParse('$x');
    if (d == null || !d.isFinite) return null;
    n.add(d.round().clamp(0, 1000));
  }
  return n[2] > n[0] && n[3] > n[1] ? n : null;
}

/// 문항 기록(item_region_1k, 없으면 bbox_1k)을 왼쪽 단부터 위에서 아래로 M1, M2 … 로 붙인다.
/// 서버(supabase/functions/_shared/concept_book.ts masksFromCrops)와 같은 순서·이름이어야 한다.
List<ConceptPageMask> conceptPageMasks(List<Map<String, dynamic>> crops) {
  final items = <({List<int> box, String num})>[];
  for (final c in crops) {
    final b = _box(c['item_region_1k']) ?? _box(c['bbox_1k']);
    if (b == null) continue;
    final raw = '${c['problem_number'] ?? ''}'.trim();
    items.add((box: b, num: raw.length > 20 ? raw.substring(0, 20) : raw));
  }
  items.sort((a, b) {
    final x = a.box[1].compareTo(b.box[1]);
    return x != 0 ? x : a.box[0].compareTo(b.box[0]);
  });
  return [
    for (var i = 0; i < items.length; i += 1)
      ConceptPageMask(
          label: 'M${i + 1}', bbox1k: items[i].box, problemNumber: items[i].num.isEmpty ? null : items[i].num),
  ];
}

/// 쪽 이미지에 회색 상자와 이름(M1 …)을 그린다.
Uint8List drawConceptPageMasks(Uint8List png, List<ConceptPageMask> masks) {
  final image = img.decodePng(png);
  if (image == null) throw StateError('쪽 이미지를 읽지 못했습니다.');
  final fill = img.ColorRgb8(0xBD, 0xBD, 0xBD);
  final ink = img.ColorRgb8(0x4A, 0x4A, 0x4A);
  final font = image.width >= 1600 ? img.arial48 : img.arial24;
  for (final m in masks) {
    final y0 = (m.bbox1k[0] / 1000 * image.height).round();
    final x0 = (m.bbox1k[1] / 1000 * image.width).round();
    final y1 = (m.bbox1k[2] / 1000 * image.height).round();
    final x1 = (m.bbox1k[3] / 1000 * image.width).round();
    img.fillRect(image, x1: x0, y1: y0, x2: x1, y2: y1, color: fill);
    img.drawString(image, m.label, font: font, x: x0 + 8, y: y0 + 6, color: ink);
  }
  return Uint8List.fromList(img.encodePng(image));
}

// ───────── 초안 기록 ─────────

String _s(dynamic v) => v == null ? '' : '$v';
int? _i(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));
List<int> _ints(dynamic v) {
  if (v is! List) return const [];
  final out = <int>[];
  for (final x in v) {
    final n = _i(x);
    if (n != null) out.add(n);
  }
  return out;
}

List<String> _strings(dynamic v) => v is List
    ? [
        for (final x in v)
          if (x != null && '$x'.trim().isNotEmpty) '$x'.trim()
      ]
    : const [];
List<Map<String, dynamic>> _maps(dynamic v) => v is List
    ? [
        for (final x in v)
          if (x is Map) Map<String, dynamic>.from(x)
      ]
    : const [];
Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : const {};

class DraftBlock {
  const DraftBlock({
    required this.id,
    required this.rawPage,
    required this.read,
    required this.kind,
    required this.title,
    required this.text,
    required this.figureDescription,
    required this.bbox1k,
    required this.uncertain,
  });

  factory DraftBlock.fromJson(Map<String, dynamic> m) => DraftBlock(
        id: _s(m['id']),
        rawPage: _i(m['raw_page']) ?? 0,
        read: _s(m['read']),
        kind: _s(m['kind']),
        title: _s(m['title']),
        text: _s(m['text']),
        figureDescription: _s(m['figure_description']),
        bbox1k: _box(m['bbox_1k']),
        uncertain: m['uncertain'] == true,
      );

  final String id;
  final int rawPage;
  final String read;
  final String kind;
  final String title;
  final String text;
  final String figureDescription;
  final List<int>? bbox1k;
  final bool uncertain;
}

class DraftDisagreement {
  const DraftDisagreement(
      {required this.id, required this.type, this.similarity, required this.aText, required this.bText});

  factory DraftDisagreement.fromJson(Map<String, dynamic> m) => DraftDisagreement(
        id: _s(m['id']),
        type: _s(m['type']),
        similarity: m['similarity'] is num ? (m['similarity'] as num).toDouble() : null,
        aText: _s(m['a_text']),
        bText: _s(m['b_text']),
      );

  final String id;

  /// text_differs · missing_in_b · only_in_b
  final String type;
  final double? similarity;
  final String aText;
  final String bText;

  String get label => switch (type) {
        'missing_in_b' => '두 번째 읽기에는 없음',
        'only_in_b' => '첫 번째 읽기에는 없음',
        _ => '두 번 읽은 글자가 다름${similarity == null ? '' : '(일치 ${(similarity! * 100).round()}%)'}',
      };
}

class DraftConcept {
  const DraftConcept({
    required this.title,
    required this.conceptType,
    required this.content,
    required this.sourceBlocks,
    required this.criterionNotes,
    required this.needsCheck,
    this.anchor = -1,
  });

  factory DraftConcept.fromJson(Map<String, dynamic> m) => DraftConcept(
        title: _s(m['title']),
        conceptType: _s(m['concept_type']),
        content: _s(m['content']),
        sourceBlocks: _strings(m['source_blocks']),
        criterionNotes: _s(m['criterion_notes']),
        needsCheck: _s(m['needs_check']),
        anchor: _i(m['anchor']) ?? -1,
      );

  /// 주제 묶음: 바로 앞에 알아야 하는 같은 초안 개념 번호(AI 제안, v3부터). 없으면 -1.
  final int anchor;

  final String title;

  /// AI가 붙인 유형 이름(확정된 유형이거나 새 유형 제안). 첫 판(v1) 초안은 영어 종류라 [draftTypeName]으로 읽는다.
  final String conceptType;
  final String content;
  final List<String> sourceBlocks;
  final String criterionNotes;
  final String needsCheck;

  String get typeName => draftTypeName(conceptType);
}

/// 첫 판(v1) 초안의 영어 종류 → 기본 유형 이름. other 는 유형을 정하지 않은 것으로 본다.
const Map<String, String> _v1TypeNames = {
  'definition': '정의',
  'property': '성질',
  'method': '방법',
  'notation': '표현',
  'caution': '주의',
  'other': '',
};

String draftTypeName(String conceptType) => _v1TypeNames[conceptType] ?? conceptType.trim();

/// 유형 이름 비교(앞뒤·연속 공백, 대소문자 무시). 서버 lower(btrim(name)) 과 맞춘다.
String conceptTypeKey(String name) => name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// 확정된 개념 유형(concept_types).
class ConceptTypeInfo {
  const ConceptTypeInfo({required this.name, required this.description, required this.legacySubType});

  factory ConceptTypeInfo.fromJson(Map<String, dynamic> m) => ConceptTypeInfo(
        name: _s(m['name']).trim(),
        description: _s(m['description']).trim(),
        legacySubType: kConceptSubTypes.contains(m['legacy_sub_type']) ? m['legacy_sub_type'] as String : '정리',
      );

  final String name;
  final String description;

  /// 기존 구분(정의·연산·정리). 확정 때 concepts.sub_type·kind 로 들어간다.
  final String legacySubType;
}

/// AI가 제안한 새 유형과 운영자 결정. accept: null 은 아직 정하지 않음.
class ReviewNewType {
  const ReviewNewType({
    required this.name,
    required this.description,
    required this.legacySubType,
    required this.closestExisting,
    required this.reason,
    this.accept,
    this.origin,
  });

  factory ReviewNewType.fromJson(Map<String, dynamic> m) => ReviewNewType(
        name: _s(m['name']).trim(),
        description: _s(m['description']).trim(),
        legacySubType: kConceptSubTypes.contains(m['legacy_sub_type']) ? m['legacy_sub_type'] as String : '정리',
        closestExisting: _s(m['closest_existing']).trim(),
        reason: _s(m['reason']).trim(),
        accept: m['accept'] is bool ? m['accept'] as bool : null,
        origin: m['origin'] == 'think' ? 'think' : null,
      );

  final String name;
  final String description;
  final String legacySubType;

  /// 거절하면 대신 쓸 확정된 유형 이름(없으면 빈 문자열).
  final String closestExisting;
  final String reason;
  final bool? accept;

  /// 'think' 면 검토 대화에서 승인한 카드가 더한 유형(AI 초안에는 없다).
  final String? origin;

  bool get fromThink => origin == 'think';

  ReviewNewType copyWith({String? legacySubType, bool? accept}) => ReviewNewType(
        name: name,
        description: description,
        legacySubType: legacySubType ?? this.legacySubType,
        closestExisting: closestExisting,
        reason: reason,
        accept: accept ?? this.accept,
        origin: origin,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'legacy_sub_type': legacySubType,
        'closest_existing': closestExisting,
        'accept': accept,
        if (origin != null) ...{'origin': origin, 'reason': reason},
      };
}

const Map<String, String> kDraftExcludeReasonLabels = {
  'problem_fragment': '문항 조각',
  'section_label': '구역 이름',
  'illustration': '장식 그림',
  'answer_reference': '정답 안내',
  'duplicate': '중복',
  'other': '기타',
};

/// 기존 구분(정의·연산·정리). 유형마다 하나씩 정해 두고, 정의 → kind definition, 나머지 → theorem(확정 RPC가 정한다).
const List<String> kConceptSubTypes = ['정의', '연산', '정리'];

class DraftExclusion {
  const DraftExclusion({required this.blockIds, required this.reasonType, required this.reason});

  factory DraftExclusion.fromJson(Map<String, dynamic> m) =>
      DraftExclusion(blockIds: _strings(m['block_ids']), reasonType: _s(m['reason_type']), reason: _s(m['reason']));

  final List<String> blockIds;
  final String reasonType;
  final String reason;
}

class DraftChecks {
  const DraftChecks({
    this.unknownIds = const [],
    this.unaccounted = const [],
    this.formulaWarnings = const [],
    this.conceptsWithoutSource = const [],
    this.unknownTypes = const [],
  });

  factory DraftChecks.fromJson(Map<String, dynamic> m) => DraftChecks(
        unknownTypes: _ints(m['unknown_types']),
        unknownIds: _strings(m['unknown_ids']),
        unaccounted: _strings(m['unaccounted']),
        formulaWarnings: [
          for (final w in _maps(m['formula_warnings'])) (concept: _i(w['concept']) ?? -1, formula: _s(w['formula'])),
        ],
        conceptsWithoutSource: _ints(m['concepts_without_source']),
      );

  final List<String> unknownIds;
  final List<String> unaccounted;
  final List<({int concept, String formula})> formulaWarnings;
  final List<int> conceptsWithoutSource;

  /// 유형이 목록에도 새 유형 제안에도 없는 개념.
  final List<int> unknownTypes;

  int get issueCount =>
      unknownIds.length +
      unaccounted.length +
      formulaWarnings.length +
      conceptsWithoutSource.length +
      unknownTypes.length;
}

class FolderPlacement {
  const FolderPlacement({required this.path, required this.reason});

  final List<String> path;
  final String reason;
}

/// 폴더 제안 때 AI가 본 겹침. 알리기만 하고 초안은 그대로다.
class FolderOverlap {
  const FolderOverlap({required this.other, required this.reason});

  final String other;
  final String reason;

  String get label => reason.isEmpty ? other : '$other ($reason)';
}

class FolderPlan {
  const FolderPlan({
    required this.notes,
    required this.newFolderReasons,
    required this.placements,
    required this.roots,
    required this.unknownRoot,
    required this.unplaced,
    required this.newFolders,
    this.overlaps = const {},
    this.pendingDrafts = 0,
    this.costUsd,
  });

  factory FolderPlan.fromJson(Map<String, dynamic> m) {
    final checks = _map(m['checks']);
    final placements = <int, FolderPlacement>{};
    for (final p in _maps(m['placements'])) {
      final i = _i(p['concept']);
      if (i == null || placements.containsKey(i)) continue;
      placements[i] = FolderPlacement(path: _strings(p['path']), reason: _s(p['reason']));
    }
    final overlaps = <int, List<FolderOverlap>>{};
    for (final o in _maps(m['overlaps'])) {
      final i = _i(o['concept']);
      final other = _s(o['other']).trim();
      if (i == null || other.isEmpty) continue;
      (overlaps[i] ??= []).add(FolderOverlap(other: other, reason: _s(o['reason']).trim()));
    }
    return FolderPlan(
      overlaps: overlaps,
      pendingDrafts: _i(m['pending_drafts']) ?? 0,
      notes: _s(m['notes']),
      newFolderReasons: {
        for (final f in _maps(m['folders'])) _strings(f['path']).join(' > '): _s(f['reason']),
      },
      placements: placements,
      roots: _strings(m['roots']),
      unknownRoot: _ints(checks['unknown_root']),
      unplaced: _ints(checks['unplaced']),
      newFolders: [for (final p in (checks['new_folders'] as List? ?? const [])) _strings(p)],
      costUsd: m['cost_usd'] is num ? (m['cost_usd'] as num).toDouble() : null,
    );
  }

  final String notes;

  /// 새 폴더 경로('대수 > 수와 연산 > 소인수분해') → AI가 든 이유.
  final Map<String, String> newFolderReasons;
  final Map<int, FolderPlacement> placements;
  final List<String> roots;
  final List<int> unknownRoot;
  final List<int> unplaced;
  final List<List<String>> newFolders;

  /// AI 개념 번호 → 라이브러리나 다른 초안과 겹칠 수 있다는 안내.
  final Map<int, List<FolderOverlap>> overlaps;

  /// 제안할 때 함께 본 다른 열린 초안 수.
  final int pendingDrafts;
  final double? costUsd;
}

/// 운영자 검토 한 줄. 저장한 것만 확정에 쓰인다.
enum ReviewMark { keep, edit, drop }

/// 확정할 때 이 항목을 라이브러리의 기존 개념과 어떻게 둘지(운영자 결정 2026-10-20).
/// 출처만 연결·대표 수정안·보류는 여러 교재 설명 통합 3단계에서 더했다.
enum ReviewRelationKind {
  newConcept('new', '새 개념'),
  statement('statement', '기존 개념의 다른 서술'),
  source('source', '기존 개념에 출처만 연결'),
  revise('revise', '기존 개념의 대표 서술 수정안'),
  extendsOf('extends', '기존 개념의 확장'),
  specialCase('special_case', '기존 개념의 특수한 경우'),
  review('review', '검토 필요'),
  hold('hold', '보류(이번에 넣지 않음)');

  const ReviewRelationKind(this.db, this.label);

  final String db;
  final String label;

  /// 기존 개념을 꼭 골라야 하는 관계. 검토 필요는 골라도 되고 안 골라도 된다.
  bool get needsTarget =>
      this == statement || this == source || this == revise || this == extendsOf || this == specialCase;
  bool get takesTarget => this != newConcept && this != hold;

  /// 새 개념을 만들지 않는 관계(유형·폴더·주제 묶음을 쓰지 않는다).
  bool get addsNoConcept => this == statement || this == source || this == revise || this == hold;

  static ReviewRelationKind? fromDb(Object? v) {
    for (final k in values) {
      if (k.db == v) return k;
    }
    return null;
  }
}

/// 검토 항목의 관계. [conceptName]·[statementLabel]은 화면 표시용이고 확정은 [conceptId]·[statementId]만 본다.
class ReviewRelation {
  const ReviewRelation({required this.kind, this.conceptId, this.conceptName, this.statementId, this.statementLabel});

  static ReviewRelation? fromJson(Object? v) {
    if (v is! Map) return null;
    final kind = ReviewRelationKind.fromDb(v['kind']);
    if (kind == null) return null;
    final id = _s(v['concept_id']).trim();
    final name = _s(v['concept_name']).trim();
    final st = _s(v['statement_id']).trim();
    final stLabel = _s(v['statement_label']).trim();
    final hasSt = kind == ReviewRelationKind.source && id.isNotEmpty && st.isNotEmpty;
    return ReviewRelation(
      kind: kind,
      conceptId: kind.takesTarget && id.isNotEmpty ? id : null,
      conceptName: kind.takesTarget && name.isNotEmpty ? name : null,
      statementId: hasSt ? st : null,
      statementLabel: hasSt && stLabel.isNotEmpty ? stLabel : null,
    );
  }

  final ReviewRelationKind kind;
  final String? conceptId;
  final String? conceptName;

  /// 출처만 연결할 때 이을 다른 서술. null 이면 기본 서술.
  final String? statementId;
  final String? statementLabel;

  bool get missingTarget => kind.needsTarget && conceptId == null;

  Map<String, dynamic> toJson() => {
        'kind': kind.db,
        if (conceptId != null) 'concept_id': conceptId,
        if (conceptName != null) 'concept_name': conceptName,
        if (statementId != null) 'statement_id': statementId,
        if (statementLabel != null) 'statement_label': statementLabel,
      };

  @override
  bool operator ==(Object other) =>
      other is ReviewRelation &&
      other.kind == kind &&
      other.conceptId == conceptId &&
      other.conceptName == conceptName &&
      other.statementId == statementId &&
      other.statementLabel == statementLabel;

  @override
  int get hashCode => Object.hash(kind, conceptId, conceptName, statementId, statementLabel);
}

class ReviewItem {
  const ReviewItem({
    String? key,
    required this.index,
    required this.mark,
    required this.title,
    required this.content,
    required this.type,
    required this.folder,
    this.blocks,
    this.mergedInto,
    this.anchor,
    this.relation,
  }) : key = key ?? 'c$index';

  factory ReviewItem.fromJson(Map<String, dynamic> m) {
    final index = _i(m['index']) ?? -1;
    final key = _s(m['key']).trim();
    final merged = _s(m['merged_into']).trim();
    final anchor = _s(m['anchor']).trim();
    return ReviewItem(
      key: key.isEmpty ? null : key,
      index: index,
      mark: ReviewMark.values.firstWhere((v) => v.name == m['mark'], orElse: () => ReviewMark.keep),
      title: _s(m['title']),
      content: _s(m['content']),
      type: _s(m['type']).trim(),
      folder: _strings(m['folder']),
      blocks: m['blocks'] is List ? _strings(m['blocks']) : null,
      mergedInto: merged.isEmpty ? null : merged,
      anchor: anchor.isEmpty ? null : anchor,
      relation: ReviewRelation.fromJson(m['relation']),
    );
  }

  /// 검토 항목 이름표. AI 개념 하나는 c{index}, 나눈 조각은 c{index}.{n}. 대화 카드가 이것으로 항목을 가리킨다.
  final String key;

  /// AI 초안의 개념 번호. 나눈 조각도 원래 개념 번호를 갖는다.
  final int index;
  final ReviewMark mark;
  final String title;
  final String content;

  /// 개념 유형 이름. 비어 있으면 아직 정하지 않았다.
  final String type;

  /// 영역 이름부터 시작하는 폴더 경로. 비어 있으면 아직 자리를 정하지 않았다.
  final List<String> folder;

  /// 나누기·합치기로 정한 근거 블록. null 이면 AI 개념의 근거 블록을 쓴다.
  final List<String>? blocks;

  /// 합치기로 빠진 항목이면 남긴 항목의 key.
  final String? mergedInto;

  /// 주제 묶음: 바로 앞에 알아야 하는 다른 검토 항목의 key. 확정 때 같은 폴더끼리만 이어진다.
  final String? anchor;

  /// 기존 개념과의 관계. null 이면 정하지 않았고, 같은 이름·겹침이 있으면 확정 때 "검토 필요"로 들어간다.
  final ReviewRelation? relation;

  bool get kept => mark != ReviewMark.drop;

  /// 새 개념이 아니라 기존 개념의 다른 서술로 붙는 항목(유형·폴더·주제 묶음을 쓰지 않는다).
  bool get asStatement => relation?.kind == ReviewRelationKind.statement;

  /// 새 개념을 만들지 않는 항목(다른 서술·출처만·수정안·보류). 유형·폴더·주제 묶음을 쓰지 않는다.
  bool get noNewConcept => relation?.kind.addsNoConcept ?? false;

  /// 보류해 이번 확정에 넣지 않는 항목.
  bool get held => relation?.kind == ReviewRelationKind.hold;

  /// AI 개념 하나가 그대로 이어진 항목(나누기 조각이 아님).
  bool get isOriginal => key == 'c$index';

  ReviewItem copyWith({
    ReviewMark? mark,
    String? title,
    String? content,
    String? type,
    List<String>? folder,
    bool clearMerged = false,
    String? anchor,
    bool clearAnchor = false,
    ReviewRelation? relation,
    bool clearRelation = false,
  }) =>
      ReviewItem(
        key: key,
        index: index,
        mark: mark ?? this.mark,
        title: title ?? this.title,
        content: content ?? this.content,
        type: type ?? this.type,
        folder: folder ?? this.folder,
        blocks: blocks,
        mergedInto: clearMerged ? null : mergedInto,
        anchor: clearAnchor ? null : (anchor ?? this.anchor),
        relation: clearRelation ? null : (relation ?? this.relation),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'index': index,
        'mark': mark.name,
        'title': title,
        'content': content,
        'type': type,
        'folder': folder,
        if (blocks != null) 'blocks': blocks,
        if (mergedInto != null) 'merged_into': mergedInto,
        if (anchor != null) 'anchor': anchor,
        if (relation != null) 'relation': relation!.toJson(),
      };
}

class ConceptDraftRecord {
  const ConceptDraftRecord({
    required this.id,
    required this.academyId,
    required this.bookId,
    required this.gradeLabel,
    required this.bookName,
    required this.unitPath,
    required this.pages,
    required this.displayPages,
    required this.status,
    required this.model,
    required this.summary,
    required this.concepts,
    required this.excluded,
    required this.questions,
    required this.blocks,
    required this.disagreements,
    required this.checks,
    required this.criteria,
    required this.folderPlan,
    required this.review,
    required this.reviewSavedAt,
    required this.createdAt,
    this.newTypes = const [],
    this.reviewNewTypes = const [],
    this.costUsd,
    this.rerunOf,
    this.replacedBy,
  });

  factory ConceptDraftRecord.fromRow(Map<String, dynamic> row) {
    final draft = _map(row['draft']);
    final prepared = _map(row['prepared']);
    final review = _map(row['review']);
    final reviewItems = [for (final m in _maps(review['concepts'])) ReviewItem.fromJson(m)];
    return ConceptDraftRecord(
      id: _s(row['id']),
      academyId: _s(row['academy_id']),
      bookId: _s(row['book_id']),
      gradeLabel: _s(row['grade_label']),
      bookName: _s(row['book_name']),
      unitPath: _strings(row['unit_path']),
      pages: _ints(row['pages']),
      displayPages: {
        for (final m in _maps(row['page_meta']))
          if (_i(m['raw_page']) != null) _i(m['raw_page'])!: _i(m['display_page']),
      },
      status: _s(row['status']),
      model: _s(row['model']),
      summary: _s(draft['summary']),
      concepts: [for (final m in _maps(draft['concepts'])) DraftConcept.fromJson(m)],
      excluded: [for (final m in _maps(draft['excluded'])) DraftExclusion.fromJson(m)],
      questions: _strings(draft['questions']),
      blocks: [for (final m in _maps(prepared['blocks'])) DraftBlock.fromJson(m)],
      disagreements: [for (final m in _maps(prepared['disagreements'])) DraftDisagreement.fromJson(m)],
      checks: DraftChecks.fromJson(_map(row['checks'])),
      criteria: [
        for (final m in _maps(row['criteria']))
          '${_s(m['title'])}${m['state'] == 'draft' ? ' (초안)' : ' v${_s(m['version'])}'}'
      ],
      folderPlan: row['folder_plan'] is Map ? FolderPlan.fromJson(_map(row['folder_plan'])) : null,
      review: reviewItems,
      reviewSavedAt: row['review_saved_at'] as String?,
      createdAt: DateTime.tryParse(_s(row['created_at'])),
      newTypes: [
        for (final m in _maps(draft['new_types']))
          if (_s(m['name']).trim().isNotEmpty) ReviewNewType.fromJson({...m, 'accept': null}),
      ],
      reviewNewTypes: [for (final m in _maps(review['new_types'])) ReviewNewType.fromJson(m)],
      costUsd: row['cost_usd'] is num ? (row['cost_usd'] as num).toDouble() : null,
      rerunOf: row['rerun_of'] as String?,
      replacedBy: row['replaced_by'] as String?,
    );
  }

  final String id;
  final String academyId;
  final String bookId;
  final String gradeLabel;
  final String bookName;
  final List<String> unitPath;
  final List<int> pages;

  /// PDF 쪽 → 인쇄 쪽(문항 기록에 있던 값). 모르면 null.
  final Map<int, int?> displayPages;

  /// open · confirmed · discarded · replaced(다시 정리함)
  final String status;
  final String model;
  final String summary;

  /// 다시 정리해 만든 초안이면 앞 초안 id, 다시 정리해 닫혔으면 새 초안 id.
  final String? rerunOf;
  final String? replacedBy;
  final List<DraftConcept> concepts;
  final List<DraftExclusion> excluded;
  final List<String> questions;
  final List<DraftBlock> blocks;
  final List<DraftDisagreement> disagreements;
  final DraftChecks checks;

  /// 정리할 때 쓴 기준 이름(판).
  final List<String> criteria;
  final FolderPlan? folderPlan;

  /// 저장된 검토. 비어 있으면 아직 저장한 적 없다.
  final List<ReviewItem> review;

  /// 서버 값 그대로(확정·저장 때 같은 값을 돌려보낸다).
  final String? reviewSavedAt;
  final DateTime? createdAt;

  /// AI가 제안한 새 유형(결정 전).
  final List<ReviewNewType> newTypes;

  /// 저장된 검토의 새 유형 결정.
  final List<ReviewNewType> reviewNewTypes;
  final double? costUsd;

  bool get isOpen => status == 'open';

  Map<String, DraftBlock> get blocksById => {for (final b in blocks) b.id: b};

  List<DraftBlock> blocksFor(int index) {
    if (index < 0 || index >= concepts.length) return const [];
    return _blocksOf(concepts[index].sourceBlocks);
  }

  List<DraftBlock> _blocksOf(List<String> ids) {
    final byId = blocksById;
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// 검토 항목의 근거 블록. 나누기·합치기로 정했으면 그 블록, 아니면 AI 개념의 블록.
  List<DraftBlock> blocksForItem(ReviewItem it) => it.blocks == null ? blocksFor(it.index) : _blocksOf(it.blocks!);

  /// 확정하면 출처로 붙을 쪽(근거 블록의 쪽). 서버 확정 RPC와 같은 규칙이다.
  List<int> sourcePages(int index) => ({for (final b in blocksFor(index)) b.rawPage}.toList()..sort());

  List<int> sourcePagesFor(ReviewItem it) => ({for (final b in blocksForItem(it)) b.rawPage}.toList()..sort());

  List<DraftDisagreement> disagreementsFor(int index) {
    final ids = index >= 0 && index < concepts.length ? concepts[index].sourceBlocks.toSet() : const <String>{};
    return [
      for (final d in disagreements)
        if (ids.contains(d.id)) d
    ];
  }

  List<DraftDisagreement> disagreementsForItem(ReviewItem it) {
    if (it.blocks == null) return disagreementsFor(it.index);
    final ids = it.blocks!.toSet();
    return [
      for (final d in disagreements)
        if (ids.contains(d.id)) d
    ];
  }

  List<String> formulaWarningsFor(int index) => [
        for (final w in checks.formulaWarnings)
          if (w.concept == index) w.formula
      ];

  String pageLabel(int raw) {
    final d = displayPages[raw];
    return d != null && d != raw ? '본문 $d쪽(PDF $raw쪽)' : 'PDF $raw쪽';
  }
}

class ConceptDraftSummary {
  const ConceptDraftSummary({
    required this.id,
    required this.bookName,
    required this.gradeLabel,
    required this.unitPath,
    required this.pages,
    required this.status,
    required this.conceptCount,
    required this.hasFolderPlan,
    required this.reviewSaved,
    this.createdAt,
  });

  factory ConceptDraftSummary.fromRow(Map<String, dynamic> row) => ConceptDraftSummary(
        id: _s(row['id']),
        bookName: _s(row['book_name']),
        gradeLabel: _s(row['grade_label']),
        unitPath: _strings(row['unit_path']),
        pages: _ints(row['pages']),
        status: _s(row['status']),
        conceptCount: _i(row['concept_count']) ?? 0,
        hasFolderPlan: row['has_folder_plan'] == true,
        reviewSaved: row['review_saved_at'] != null,
        createdAt: DateTime.tryParse(_s(row['created_at'])),
      );

  final String id;
  final String bookName;
  final String gradeLabel;
  final List<String> unitPath;
  final List<int> pages;
  final String status;
  final int conceptCount;
  final bool hasFolderPlan;
  final bool reviewSaved;
  final DateTime? createdAt;
}

/// 초안 상태 이름(목록·검토 창).
String conceptDraftStatusLabel(String status) => switch (status) {
      'open' => '검토 중',
      'confirmed' => '확정함',
      'discarded' => '버림',
      'replaced' => '다시 정리함',
      _ => status,
    };

class ConceptPageImage {
  const ConceptPageImage({required this.path, required this.width, required this.height});

  final String path;
  final int width;
  final int height;
}

/// PNG 머리(IHDR)에서 가로·세로를 읽는다.
(int, int)? pngSize(List<int> head) {
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (head.length < 24) return null;
  for (var i = 0; i < sig.length; i += 1) {
    if (head[i] != sig[i]) return null;
  }
  int be(int o) => (head[o] << 24) | (head[o + 1] << 16) | (head[o + 2] << 8) | head[o + 3];
  final w = be(16);
  final h = be(20);
  return w > 0 && h > 0 ? (w, h) : null;
}

/// 폴더 행(id·name·parent_id·code) → 영역부터 시작하는 경로. 바로가기·끊긴 폴더는 뺀다.
List<List<String>> libraryPathsFromRows(List<Map<String, dynamic>> rows) {
  final byId = {for (final r in rows) '${r['id']}': r};
  List<String>? pathOf(Map<String, dynamic> row) {
    final out = <String>[];
    Map<String, dynamic>? cur = row;
    for (var i = 0; cur != null && i < 12; i += 1) {
      if (cur['code'] == 'SHORTCUT') return null;
      out.insert(0, '${cur['name'] ?? ''}'.trim());
      final parent = cur['parent_id'];
      if (parent == null) return out;
      cur = byId['$parent'];
    }
    return null;
  }

  final paths = <List<String>>[];
  for (final r in rows) {
    final p = pathOf(r);
    if (p != null && p.every((s) => s.isNotEmpty)) paths.add(p);
  }
  paths.sort((a, b) => a.join('\u0000').compareTo(b.join('\u0000')));
  return paths;
}

// ───────── 검토 계산 ─────────

/// 저장된 검토가 있으면 그것을, 없으면 AI 초안과 폴더 제안으로 처음 검토를 만든다(저장 전).
/// 저장된 검토는 저장한 순서·나눈 조각을 그대로 두고, 빠진 AI 개념만 뒤에 더한다.
List<ReviewItem> initialReview(ConceptDraftRecord r) {
  if (r.review.isNotEmpty) {
    final saved = [
      for (final it in r.review)
        if (it.index >= 0 && it.index < r.concepts.length)
          // 유형 없이 저장된 검토(유형 기능 전)는 AI가 붙인 유형으로 채운다.
          it.type.isEmpty ? it.copyWith(type: r.concepts[it.index].typeName) : it,
    ];
    final covered = {for (final it in saved) it.index};
    return [
      ...saved,
      for (var i = 0; i < r.concepts.length; i += 1)
        if (!covered.contains(i)) _fromDraft(r, i),
    ];
  }
  return [for (var i = 0; i < r.concepts.length; i += 1) _fromDraft(r, i)];
}

ReviewItem _fromDraft(ConceptDraftRecord r, int i) {
  final c = r.concepts[i];
  final plan = r.folderPlan;
  final placed = plan?.placements[i];
  final usable =
      placed != null && placed.path.length >= 2 && (plan!.roots.isEmpty || plan.roots.contains(placed.path.first));
  return ReviewItem(
    index: i,
    mark: ReviewMark.keep,
    title: c.title,
    content: c.content,
    type: c.typeName,
    folder: usable ? placed.path : const [],
    anchor: c.anchor >= 0 && c.anchor != i && c.anchor < r.concepts.length ? 'c${c.anchor}' : null,
  );
}

/// 검토 항목이 붙을 항목. 합쳐서 뺀 항목을 가리키면 합친 쪽을 따라간다. 없거나 그냥 뺀 항목이면 null.
ReviewItem? reviewAnchorTarget(List<ReviewItem> items, ReviewItem it) {
  final byKey = {for (final x in items) x.key: x};
  var target = it.anchor == null ? null : byKey[it.anchor];
  if (target != null && !target.kept) target = target.mergedInto == null ? null : byKey[target.mergedInto];
  return target != null && target.kept && target.key != it.key ? target : null;
}

/// 남긴 항목끼리 이을 묶음(같은 폴더만, 확정 RPC와 같은 규칙). key → 붙을 key.
Map<String, String> reviewAnchorLinks(List<ReviewItem> items) {
  final out = <String, String>{};
  for (final it in items) {
    if (!it.kept || it.noNewConcept) continue;
    final t = reviewAnchorTarget(items, it);
    if (t != null && !t.noNewConcept && t.folder.join('\u0000') == it.folder.join('\u0000')) out[it.key] = t.key;
  }
  return out;
}

/// 묶음 고리에 걸린 항목 key(있으면 확정할 수 없다).
List<String> reviewAnchorCycle(List<ReviewItem> items) {
  final links = reviewAnchorLinks(items);
  final out = <String>[];
  for (final k in links.keys) {
    var cur = links[k];
    for (var steps = 0; cur != null && steps <= links.length; steps++) {
      if (cur == k) {
        out.add(k);
        break;
      }
      cur = links[cur];
    }
  }
  return out;
}

/// AI가 제안한 새 유형에 저장된 결정(받아들임·거절·기존 구분)을 입힌다. 저장한 적 없으면 모두 결정 전.
/// 검토 대화 카드로 더한 유형(origin think)은 AI 제안 뒤에 붙인다.
List<ReviewNewType> initialNewTypes(ConceptDraftRecord r) {
  final saved = {for (final t in r.reviewNewTypes) conceptTypeKey(t.name): t};
  final ai = {for (final t in r.newTypes) conceptTypeKey(t.name)};
  return [
    for (final t in r.newTypes)
      () {
        final s = saved[conceptTypeKey(t.name)];
        return s == null ? t : t.copyWith(legacySubType: s.legacySubType, accept: s.accept);
      }(),
    for (final t in r.reviewNewTypes)
      if (t.fromThink && t.name.isNotEmpty && !ai.contains(conceptTypeKey(t.name))) t,
  ];
}

/// 개념 유형의 기존 구분. 확정된 유형이면 그 값, 받아들일 수 있는(거절 안 한) 새 유형이면 제안 값. 모르면 null.
String? legacySubTypeOf(String type, List<ConceptTypeInfo> types, List<ReviewNewType> newTypes) {
  final key = conceptTypeKey(type);
  if (key.isEmpty) return null;
  for (final t in types) {
    if (conceptTypeKey(t.name) == key) return t.legacySubType;
  }
  for (final t in newTypes) {
    if (conceptTypeKey(t.name) == key && t.accept != false) return t.legacySubType;
  }
  return null;
}

/// 새 유형을 받아들이거나 거절한다. 거절하면 그 유형을 쓰던 개념은 AI가 든 가장 가까운 유형으로 바꾸고,
/// 다시 받아들이면 AI가 원래 그 유형을 붙였고 아직 대신 쓴 유형 그대로인 개념만 되돌린다.
({List<ReviewItem> items, List<ReviewNewType> newTypes}) decideNewType(
  ConceptDraftRecord r,
  List<ReviewItem> items,
  List<ReviewNewType> newTypes,
  String name,
  bool accept,
) {
  final key = conceptTypeKey(name);
  ReviewNewType? target;
  for (final t in newTypes) {
    if (conceptTypeKey(t.name) == key) target = t;
  }
  if (target == null) return (items: items, newTypes: newTypes);
  final fallback = target.closestExisting;
  final nextItems = [
    for (final it in items)
      if (!accept && conceptTypeKey(it.type) == key)
        it.copyWith(type: fallback)
      else if (accept &&
          it.index >= 0 &&
          it.index < r.concepts.length &&
          conceptTypeKey(r.concepts[it.index].typeName) == key &&
          conceptTypeKey(it.type) == conceptTypeKey(fallback))
        it.copyWith(type: target.name)
      else
        it,
  ];
  return (
    items: nextItems,
    newTypes: [for (final t in newTypes) conceptTypeKey(t.name) == key ? t.copyWith(accept: accept) : t],
  );
}

/// 이 새 유형을 쓰는(빼지 않은) 개념 수.
int newTypeUseCount(List<ReviewItem> items, String name) =>
    items.where((it) => it.kept && !it.noNewConcept && conceptTypeKey(it.type) == conceptTypeKey(name)).length;

/// 검토에 쓰인 폴더 경로(접두 포함)를 트리 순서로.
List<List<String>> reviewFolderPaths(List<ReviewItem> items) {
  final seen = <String, List<String>>{};
  for (final it in items) {
    if (!it.kept || it.noNewConcept) continue;
    for (var n = 1; n <= it.folder.length; n += 1) {
      final p = it.folder.sublist(0, n);
      seen.putIfAbsent(p.join('\u0000'), () => p);
    }
  }
  final out = seen.values.toList()..sort((a, b) => a.join('\u0000').compareTo(b.join('\u0000')));
  return out;
}

bool _startsWith(List<String> path, List<String> prefix) {
  if (path.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i += 1) {
    if (path[i] != prefix[i]) return false;
  }
  return true;
}

/// 폴더 이름을 바꾼다. 그 폴더(와 하위 폴더)에 둔 개념의 경로가 모두 바뀐다. 영역(첫 칸)은 바꾸지 않는다.
List<ReviewItem> renameReviewFolder(List<ReviewItem> items, List<String> path, String name) {
  final next = name.trim();
  if (path.length < 2 || next.isEmpty) return items;
  return [
    for (final it in items)
      _startsWith(it.folder, path)
          ? it.copyWith(folder: [...path.sublist(0, path.length - 1), next, ...it.folder.sublist(path.length)])
          : it,
  ];
}

/// 확정 전에 막을 것. 없으면 null.
String? reviewProblem(
  List<ReviewItem> items,
  List<String> roots, {
  List<ConceptTypeInfo> types = const [],
  List<ReviewNewType> newTypes = const [],
}) {
  final kept = items.where((it) => it.kept).toList();
  if (kept.isEmpty) return '넣을 개념이 없습니다. 하나 이상을 "그대로" 또는 "고쳐서"로 두세요.';
  final known = {for (final t in types) conceptTypeKey(t.name)};
  final proposed = {for (final t in newTypes) conceptTypeKey(t.name): t};
  final revised = <String, String>{};
  for (final it in kept) {
    final name = it.title.trim().isEmpty ? '${it.index + 1}번 개념' : '"${it.title.trim()}"';
    if (it.title.trim().isEmpty || it.content.trim().isEmpty) return '$name의 이름과 내용을 채우세요.';
    final rel = it.relation;
    if (rel != null && rel.missingTarget) return '$name을 "${rel.kind.label}"(으)로 두려면 기존 개념을 고르세요.';
    if (rel != null && rel.kind == ReviewRelationKind.revise) {
      final other = revised[rel.conceptId!];
      if (other != null) {
        return '$other와 $name이 같은 개념 "${rel.conceptName ?? '고른 개념'}"의 수정안입니다. 수정안은 개념마다 하나라서 하나만 남기세요.';
      }
      revised[rel.conceptId!] = name;
    }
    if (it.noNewConcept) continue;
    final key = conceptTypeKey(it.type);
    if (key.isEmpty) return '$name의 유형을 정하세요.';
    if (!known.contains(key)) {
      final p = proposed[key];
      if (p == null) return '$name의 유형 "${it.type.trim()}"이 유형 목록에 없습니다. 다른 유형을 고르세요.';
      if (p.accept == null) return '새 유형 "${p.name}"을 받아들일지 정하세요.';
      if (p.accept == false) return '$name은 거절한 유형 "${p.name}"을 쓰고 있습니다. 다른 유형을 고르세요.';
    }
    if (it.folder.length < 2) return '$name을 넣을 폴더를 정하세요(영역 아래 폴더).';
    if (roots.isNotEmpty && !roots.contains(it.folder.first)) return '$name의 폴더가 영역(${roots.join('·')})으로 시작하지 않습니다.';
    if (it.folder.any((s) => s.trim().isEmpty || s.length > 80)) return '$name의 폴더 이름이 비었거나 너무 깁니다.';
  }
  final cycle = reviewAnchorCycle(items);
  if (cycle.isNotEmpty) {
    final byKey = {for (final it in items) it.key: it};
    return '주제 묶음이 서로 가리킵니다(${cycle.map((k) => byKey[k]?.title.trim() ?? k).join(', ')}). 한쪽의 "붙일 개념"을 바꾸세요.';
  }
  return null;
}

/// 이름 같음 판단 키(확정 RPC의 lower(btrim(name))과 같다).
String reviewNameKey(String name) => name.trim().toLowerCase();

/// 확정하면 기존 개념과 어떻게 들어갈지 미리 센 것.
class ReviewRelationSummary {
  const ReviewRelationSummary({
    required this.chosen,
    required this.sameName,
    required this.overlap,
    required this.namesKnown,
  });

  /// 운영자가 고른 관계별 항목 수.
  final Map<ReviewRelationKind, int> chosen;

  /// 관계를 정하지 않았고 라이브러리에 같은 이름이 있어 "검토 필요"로 들어갈 항목 이름.
  final List<String> sameName;

  /// 관계를 정하지 않았고 폴더 제안 AI가 겹칠 수 있다고 해 "검토 필요"로 들어갈 항목 이름.
  final List<String> overlap;

  /// 라이브러리 이름을 읽었는지. false 면 [sameName]은 비어 있어도 확정 때 붙을 수 있다.
  final bool namesKnown;

  int get autoReviews => sameName.length + overlap.length;
  int count(ReviewRelationKind k) => chosen[k] ?? 0;
  bool get isEmpty => chosen.isEmpty && autoReviews == 0;
}

/// [libraryNames]: 라이브러리 개념 이름 키([reviewNameKey]). null 이면 읽지 못했다.
ReviewRelationSummary reviewRelationSummary(
  ConceptDraftRecord r,
  List<ReviewItem> items, {
  Set<String>? libraryNames,
}) {
  final chosen = <ReviewRelationKind, int>{};
  final same = <String>[];
  final overlap = <String>[];
  for (final it in items) {
    if (!it.kept) continue;
    final rel = it.relation;
    final title = it.title.trim().isEmpty ? '(이름 없음)' : it.title.trim();
    if (rel != null) {
      chosen[rel.kind] = (chosen[rel.kind] ?? 0) + 1;
    } else if (libraryNames != null && libraryNames.contains(reviewNameKey(it.title))) {
      same.add(title);
    } else if ((r.folderPlan?.overlaps[it.index] ?? const []).isNotEmpty) {
      overlap.add(title);
    }
  }
  return ReviewRelationSummary(chosen: chosen, sameName: same, overlap: overlap, namesKnown: libraryNames != null);
}

/// 확정 안내 문장. 고른 관계와 자동 "검토 필요"를 한두 줄로.
String? reviewRelationSentence(ReviewRelationSummary s) {
  final parts = <String>[
    for (final k in ReviewRelationKind.values)
      if (k != ReviewRelationKind.newConcept && s.count(k) > 0) '${k.label} ${s.count(k)}개',
  ];
  final lines = <String>[];
  if (parts.isNotEmpty) lines.add('기존 개념과의 관계: ${parts.join(' · ')}.');
  if (s.count(ReviewRelationKind.statement) > 0) {
    lines.add('다른 서술로 붙이는 항목은 새 개념을 만들지 않고 기존 개념에 확정 전 서술로 더합니다. 기존 확정 내용·본문은 그대로입니다.');
  }
  if (s.count(ReviewRelationKind.source) > 0) {
    lines.add('출처만 연결하는 항목은 새 개념·글 없이 이 교재 쪽을 기존 개념의 서술 출처로 잇습니다(근거 범위는 미확인으로 들어갑니다).');
  }
  if (s.count(ReviewRelationKind.revise) > 0) {
    lines.add('대표 서술 수정안은 기존 개념의 본문을 바꾸지 않고 수정안으로 저장합니다. 그 개념 창에서 이유를 적어 확정해야 바뀝니다. '
        '그 개념에 이미 수정안이 있으면 확정이 막힙니다.');
  }
  if (s.count(ReviewRelationKind.hold) > 0) {
    lines.add('보류한 항목은 이번에 넣지 않고 "보류한 항목" 목록에 남깁니다. 나중에 다시 검토하거나 버릴 수 있습니다.');
  }
  if (s.autoReviews > 0) {
    final names = [...s.sameName.map((t) => '$t(같은 이름)'), ...s.overlap.map((t) => '$t(겹칠 수 있음)')];
    final shown = names.take(4).join(', ');
    lines.add('관계를 정하지 않은 ${s.autoReviews}개는 새 개념으로 넣고 "검토 필요"로 표시합니다: $shown'
        '${names.length > 4 ? ' 외 ${names.length - 4}개' : ''}.');
  }
  if (!s.namesKnown) lines.add('라이브러리 이름을 읽지 못했습니다. 같은 이름 개념이 있으면 확정 때 "검토 필요"로 표시됩니다.');
  return lines.isEmpty ? null : lines.join('\n');
}

/// 저장된 검토와 화면의 검토가 같은지(저장 안 된 편집이 있는지).
bool sameReview(
  List<ReviewItem> a,
  List<ReviewItem> b, [
  List<ReviewNewType> typesA = const [],
  List<ReviewNewType> typesB = const [],
]) {
  if (a.length != b.length || typesA.length != typesB.length) return false;
  for (var i = 0; i < a.length; i += 1) {
    final x = a[i].toJson();
    final y = b[i].toJson();
    if (x['key'] != y['key'] ||
        x['index'] != y['index'] ||
        x['merged_into'] != y['merged_into'] ||
        x['anchor'] != y['anchor'] ||
        a[i].relation != b[i].relation ||
        (x['blocks'] as List?)?.join('\u0000') != (y['blocks'] as List?)?.join('\u0000') ||
        x['mark'] != y['mark'] ||
        x['title'] != y['title'] ||
        x['content'] != y['content'] ||
        x['type'] != y['type'] ||
        (x['folder'] as List).join('\u0000') != (y['folder'] as List).join('\u0000')) {
      return false;
    }
  }
  for (var i = 0; i < typesA.length; i += 1) {
    final x = typesA[i];
    final y = typesB[i];
    if (x.name != y.name || x.accept != y.accept || x.legacySubType != y.legacySubType) return false;
  }
  return true;
}

/// 남은 쪽 읽기 횟수(쪽마다 두 번)에 정리·폴더 제안을 더한 대략 비용.
double conceptDraftCostEstimate(int readsToDo) => readsToDo * kConceptDraftCostPerRead + kConceptDraftCostPerDraft;

/// 여러 초안을 한 번에 확정할 계획. 검토 화면의 확정과 같은 검사를 한다.
/// 검토를 저장한 초안은 저장된 검토를, 저장하지 않은 초안은 AI 초안·폴더 제안 그대로(처음 검토)를 쓴다(운영자 결정 2026-10-19).
class DraftBatchPlan {
  const DraftBatchPlan({
    required this.ready,
    required this.blocked,
    required this.newFolders,
    required this.newTypes,
    this.overlaps = const [],
    this.sameTitles = const [],
    this.asIs = const {},
    this.relations = const {},
    this.namesKnown = false,
  });

  /// 넣을 초안 id → 기존 개념과의 관계 계산.
  final Map<String, ReviewRelationSummary> relations;

  /// 라이브러리 이름을 읽었는지(같은 이름 "검토 필요" 예측을 믿을 수 있는지).
  final bool namesKnown;

  /// 넣을 초안 전체의 관계 계산.
  ReviewRelationSummary get relationTotal {
    final chosen = <ReviewRelationKind, int>{};
    final same = <String>[];
    final overlap = <String>[];
    for (final s in relations.values) {
      s.chosen.forEach((k, v) => chosen[k] = (chosen[k] ?? 0) + v);
      same.addAll(s.sameName);
      overlap.addAll(s.overlap);
    }
    return ReviewRelationSummary(chosen: chosen, sameName: same, overlap: overlap, namesKnown: namesKnown);
  }

  final List<ConceptDraftRecord> ready;

  /// 검토를 저장하지 않아 AI 초안 그대로 넣는 초안(id → 확정 전에 저장할 검토).
  final Map<String, ({List<ReviewItem> items, List<ReviewNewType> newTypes})> asIs;

  List<ReviewItem> reviewOf(ConceptDraftRecord r) => asIs[r.id]?.items ?? r.review;
  final List<({ConceptDraftRecord record, String reason})> blocked;

  /// 라이브러리에 없어 새로 만드는 폴더(여러 초안에서 같은 경로는 하나). 이름순이라 비슷한 이름이 붙어 보인다.
  final List<String> newFolders;

  /// 받아들여 유형 목록에 더해지는 새 유형(이미 있는 이름은 뺌, 이름 하나에 하나).
  final List<String> newTypes;

  /// 남기는 개념 중 폴더 제안 AI가 겹칠 수 있다고 한 것.
  final List<({String unit, String title, String other})> overlaps;

  /// 고른 초안 둘 이상에 같은 이름으로 남은 개념. 확정하면 같은 이름의 다른 판으로 들어가고,
  /// 관계를 정하지 않았으면 뒤에 넣는 쪽이 "검토 필요"로 표시된다.
  final List<({String title, int drafts})> sameTitles;

  /// 남기는 항목 수(다른 서술로 붙는 항목 포함).
  int get conceptCount => ready.fold(0, (n, r) => n + reviewOf(r).where((it) => it.kept).length);
}

/// [libraryNames]: 라이브러리 개념 이름 키([reviewNameKey]). null 이면 읽지 못했다.
/// [relationsBlocked]: 관계를 읽는 확정 RPC가 없을 때의 이유. 있으면 관계를 고른 초안은 확정하지 않는다.
DraftBatchPlan planDraftBatchConfirm(
  List<ConceptDraftRecord> records, {
  required List<List<String>> libraryPaths,
  required List<ConceptTypeInfo> types,
  Set<String>? libraryNames,
  String? relationsBlocked,
  String? compareBlocked,
}) {
  final libraryRoots = [
    for (final p in libraryPaths)
      if (p.length == 1) p.first
  ];
  final libraryKeys = {for (final p in libraryPaths) p.join('\u0000')};
  final ready = <ConceptDraftRecord>[];
  final blocked = <({ConceptDraftRecord record, String reason})>[];
  final folders = <String, String>{};
  final newTypes = <String, String>{};
  final overlaps = <({String unit, String title, String other})>[];
  final titleDrafts = <String, Set<String>>{};
  final asIs = <String, ({List<ReviewItem> items, List<ReviewNewType> newTypes})>{};
  final relations = <String, ReviewRelationSummary>{};
  for (final r in records) {
    final saved = r.reviewSavedAt != null && r.review.isNotEmpty;
    final items = saved ? r.review : initialReview(r);
    final itemTypes = saved ? r.reviewNewTypes : initialNewTypes(r);
    String? reason;
    if (!r.isOpen) {
      reason = '이미 ${conceptDraftStatusLabel(r.status)} 초안입니다.';
    } else {
      final plan = r.folderPlan?.roots ?? const <String>[];
      reason = reviewProblem(items, plan.isNotEmpty ? plan : libraryRoots, types: types, newTypes: itemTypes);
      if (reason != null && !saved) reason = 'AI 초안 그대로는 넣을 수 없습니다: $reason 검토 화면에서 정하고 저장하세요.';
      if (reason == null && relationsBlocked != null && items.any((it) => it.kept && it.relation != null)) {
        reason = relationsBlocked;
      }
      if (reason == null &&
          compareBlocked != null &&
          items.any((it) => it.kept && it.noNewConcept && !it.asStatement)) {
        reason = compareBlocked;
      }
    }
    if (reason != null) {
      blocked.add((record: r, reason: reason));
      continue;
    }
    ready.add(r);
    if (!saved) asIs[r.id] = (items: items, newTypes: itemTypes);
    relations[r.id] = reviewRelationSummary(r, items, libraryNames: libraryNames);
    for (final p in reviewFolderPaths(items.where((it) => it.kept).toList())) {
      final key = p.join('\u0000');
      if (p.length >= 2 && !libraryKeys.contains(key)) folders[key] = p.join(' > ');
    }
    final known = {for (final t in types) conceptTypeKey(t.name)};
    for (final t in itemTypes) {
      final key = conceptTypeKey(t.name);
      if (t.accept == true && key.isNotEmpty && !known.contains(key)) newTypes.putIfAbsent(key, () => t.name);
    }
    final unit = r.unitPath.isEmpty ? '(단원 없음)' : r.unitPath.last;
    final shown = <int>{};
    for (final it in items) {
      if (!it.kept) continue;
      final title = it.title.trim();
      if (title.isNotEmpty) (titleDrafts[title] ??= <String>{}).add(r.id);
      if (!shown.add(it.index)) continue;
      for (final o in r.folderPlan?.overlaps[it.index] ?? const <FolderOverlap>[]) {
        overlaps.add((unit: unit, title: title.isEmpty ? '(이름 없음)' : title, other: o.label));
      }
    }
  }
  final sortedFolders = folders.values.toList()..sort();
  final sameTitles = [
    for (final e in titleDrafts.entries)
      if (e.value.length > 1) (title: e.key, drafts: e.value.length),
  ]..sort((a, b) => a.title.compareTo(b.title));
  return DraftBatchPlan(
    ready: ready,
    blocked: blocked,
    newFolders: sortedFolders,
    newTypes: newTypes.values.toList(),
    overlaps: overlaps,
    sameTitles: sameTitles,
    asIs: asIs,
    relations: relations,
    namesKnown: libraryNames != null,
  );
}

/// "개념 초안 만들기"를 누를 수 있는 소단원(쪽 범위가 있고 문항 묶음·연습문제가 아님). 진행률의 분모.
bool conceptDraftableUnit(ConceptBookUnit u) =>
    !u.slot && !u.isExercise && u.startPage != null && u.endPage != null && u.endPage! >= u.startPage!;

enum ConceptUnitDraftState { none, open, confirmed }

/// 소단원 하나의 초안 기록. 버리거나 다시 정리한 초안은 세지 않는다.
class ConceptUnitDraft {
  const ConceptUnitDraft({this.openId, this.openCount = 0, this.confirmedCount = 0});

  /// 가장 최근에 만든 검토 중 초안.
  final String? openId;
  final int openCount;
  final int confirmedCount;

  /// 확정한 초안이 있으면 확정, 없고 검토 중 초안이 있으면 검토 중.
  ConceptUnitDraftState get state => confirmedCount > 0
      ? ConceptUnitDraftState.confirmed
      : (openCount > 0 ? ConceptUnitDraftState.open : ConceptUnitDraftState.none);
}

class ConceptDraftProgressCount {
  const ConceptDraftProgressCount({required this.total, required this.open, required this.confirmed});

  final int total;
  final int open;
  final int confirmed;

  int get drafted => open + confirmed;
  int get remaining => total - drafted;

  /// 초안을 만든(검토 중+확정) 소단원 비율. 모두 만들기 전에는 100이 되지 않게 내림한다.
  int get percent => total == 0 ? 0 : (drafted * 100) ~/ total;
}

/// 교재·소단원별 초안 기록. 소단원은 저장된 단원 경로(unit_path)가 같아야 같은 소단원이다.
class ConceptDraftCoverage {
  const ConceptDraftCoverage._(this._units);

  /// rows는 만든 시각 최근순. 버림·다시 정리함은 건너뛴다.
  factory ConceptDraftCoverage.fromRows(Iterable<Map<String, dynamic>> rows) {
    final units = <String, ConceptUnitDraft>{};
    for (final r in rows) {
      final status = _s(r['status']);
      if (status != 'open' && status != 'confirmed') continue;
      final key =
          _unitKey('${_s(r['academy_id'])}|${_s(r['book_id'])}|${_s(r['grade_label'])}', _strings(r['unit_path']));
      final cur = units[key] ?? const ConceptUnitDraft();
      units[key] = status == 'open'
          ? ConceptUnitDraft(
              openId: cur.openId ?? _s(r['id']),
              openCount: cur.openCount + 1,
              confirmedCount: cur.confirmedCount,
            )
          : ConceptUnitDraft(openId: cur.openId, openCount: cur.openCount, confirmedCount: cur.confirmedCount + 1);
    }
    return ConceptDraftCoverage._(units);
  }

  static const empty = ConceptDraftCoverage._({});

  final Map<String, ConceptUnitDraft> _units;

  static String _unitKey(String bookKey, List<String> path) => '$bookKey\u0001${path.join('\u0001')}';

  ConceptUnitDraft unit(ConceptBookEntry book, List<String> path) =>
      _units[_unitKey(book.key, path)] ?? const ConceptUnitDraft();

  /// units 중 초안을 만들 수 있는 소단원만 센다. 경로가 같은 소단원은 하나로 센다.
  ConceptDraftProgressCount progress(ConceptBookEntry book, [Iterable<ConceptBookUnit>? units]) {
    final seen = <String>{};
    var total = 0, open = 0, confirmed = 0;
    for (final u in units ?? book.units) {
      if (!conceptDraftableUnit(u) || !seen.add(u.path.join('\u0001'))) continue;
      total += 1;
      switch (unit(book, u.path).state) {
        case ConceptUnitDraftState.confirmed:
          confirmed += 1;
        case ConceptUnitDraftState.open:
          open += 1;
        case ConceptUnitDraftState.none:
          break;
      }
    }
    return ConceptDraftProgressCount(total: total, open: open, confirmed: confirmed);
  }
}
