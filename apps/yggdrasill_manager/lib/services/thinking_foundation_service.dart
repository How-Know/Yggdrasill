import 'package:supabase_flutter/supabase_flutter.dart';

class ThinkingFoundationGroupInfo {
  const ThinkingFoundationGroupInfo({
    required this.code,
    required this.title,
    required this.subtitle,
  });

  final String code;
  final String title;
  final String subtitle;

  String get displayLabel => '$code. $title';
}

const List<ThinkingFoundationGroupInfo> kThinkingFoundationGroups = [
  ThinkingFoundationGroupInfo(
    code: 'C1',
    title: '사고의 규범',
    subtitle: '수학적으로 사고할 때 지켜야 할 기준',
  ),
  ThinkingFoundationGroupInfo(
    code: 'C2',
    title: '판단의 규범',
    subtitle: '무엇을 근거로 옳고 그름을 판단할 것인가',
  ),
  ThinkingFoundationGroupInfo(
    code: 'C3',
    title: '탐구의 태도',
    subtitle: '불확실성, 오류, 어려움에 어떻게 대응할 것인가',
  ),
];

ThinkingFoundationGroupInfo thinkingFoundationGroupOf(String groupCode) {
  for (final g in kThinkingFoundationGroups) {
    if (g.code == groupCode) return g;
  }
  return kThinkingFoundationGroups.first;
}

class ThinkingFoundationExample {
  const ThinkingFoundationExample({
    required this.id,
    required this.exampleOrder,
    required this.content,
    this.relatedConceptIds = const [],
    this.relatedQuestionIds = const [],
  });

  factory ThinkingFoundationExample.fromJson(Map<String, dynamic> m) {
    List<String> strList(Object? raw) => [
          for (final x in (raw is List ? raw : const []))
            if ('$x'.trim().isNotEmpty) '$x'.trim(),
        ];
    return ThinkingFoundationExample(
      id: '${m['id'] ?? ''}',
      exampleOrder: (m['example_order'] as num?)?.toInt() ?? 1,
      content: '${m['content'] ?? ''}',
      relatedConceptIds: strList(m['related_concept_ids']),
      relatedQuestionIds: strList(m['related_question_ids']),
    );
  }

  final String id;
  final int exampleOrder;
  final String content;
  final List<String> relatedConceptIds;
  final List<String> relatedQuestionIds;

  Map<String, dynamic> toPayload() => {
        if (id.trim().isNotEmpty) 'id': id.trim(),
        'example_order': exampleOrder,
        'content': content.trim(),
        'related_concept_ids': relatedConceptIds,
        'related_question_ids': relatedQuestionIds,
      };
}

class ThinkingFoundationItem {
  const ThinkingFoundationItem({
    required this.id,
    required this.code,
    required this.domain,
    required this.groupCode,
    required this.groupTitle,
    required this.title,
    required this.definition,
    required this.learningGoals,
    required this.teachingPrinciple,
    required this.observationCriteria,
    required this.keywords,
    required this.examples,
    required this.sortOrder,
    required this.isActive,
  });

  factory ThinkingFoundationItem.fromJson(Map<String, dynamic> m) {
    List<String> strList(Object? raw) => [
          for (final x in (raw is List ? raw : const []))
            if ('$x'.trim().isNotEmpty) '$x'.trim(),
        ];
    final exList = [
      for (final r in (m['examples'] as List?) ?? const [])
        if (r is Map) ThinkingFoundationExample.fromJson(Map<String, dynamic>.from(r)),
    ]..sort((a, b) => a.exampleOrder.compareTo(b.exampleOrder));

    final groupCode = '${m['group_code'] ?? 'C1'}';
    final groupTitle = '${m['group_title'] ?? ''}'.trim();
    return ThinkingFoundationItem(
      id: '${m['id'] ?? ''}',
      code: '${m['code'] ?? ''}',
      domain: '${m['domain'] ?? 'C'}',
      groupCode: groupCode,
      groupTitle: groupTitle.isEmpty ? thinkingFoundationGroupOf(groupCode).title : groupTitle,
      title: '${m['title'] ?? ''}',
      definition: '${m['definition'] ?? ''}',
      learningGoals: strList(m['learning_goals']),
      teachingPrinciple: '${m['teaching_principle'] ?? ''}',
      observationCriteria: '${m['observation_criteria'] ?? ''}',
      keywords: strList(m['keywords']),
      examples: exList,
      sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
      isActive: m['is_active'] != false,
    );
  }

  final String id;
  final String code;
  final String domain;
  final String groupCode;
  final String groupTitle;
  final String title;
  final String definition;
  final List<String> learningGoals;
  final String teachingPrinciple;
  final String observationCriteria;
  final List<String> keywords;
  final List<ThinkingFoundationExample> examples;
  final int sortOrder;
  final bool isActive;

  bool get isAttitudeGroup => groupCode == 'C3';

  String get groupDisplayLabel => '$groupCode. $groupTitle';

  bool matchesQuery(String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (title.toLowerCase().contains(q)) return true;
    if (code.toLowerCase().contains(q)) return true;
    if (groupCode.toLowerCase().contains(q)) return true;
    if (groupTitle.toLowerCase().contains(q)) return true;
    if (definition.toLowerCase().contains(q)) return true;
    if (teachingPrinciple.toLowerCase().contains(q)) return true;
    if (observationCriteria.toLowerCase().contains(q)) return true;
    for (final g in learningGoals) {
      if (g.toLowerCase().contains(q)) return true;
    }
    for (final k in keywords) {
      if (k.toLowerCase().contains(q)) return true;
    }
    for (final ex in examples) {
      if (ex.content.toLowerCase().contains(q)) return true;
    }
    return false;
  }
}

class QuestionFoundationLink {
  const QuestionFoundationLink({
    this.id = '',
    this.questionId = '',
    required this.foundationId,
    required this.code,
    required this.groupCode,
    required this.groupTitle,
    required this.title,
    this.relevanceLevel = 'core',
    this.rationale = '',
    this.observability = 'process_required',
  });

  factory QuestionFoundationLink.fromJson(Map<String, dynamic> m) {
    final groupCode = '${m['group_code'] ?? 'C1'}';
    final rawObs = '${m['observability'] ?? 'process_required'}';
    return QuestionFoundationLink(
      id: '${m['id'] ?? ''}',
      questionId: '${m['question_id'] ?? ''}',
      foundationId: '${m['foundation_id'] ?? ''}',
      code: '${m['code'] ?? ''}',
      groupCode: groupCode,
      groupTitle: '${m['group_title'] ?? thinkingFoundationGroupOf(groupCode).title}',
      title: '${m['title'] ?? ''}',
      relevanceLevel: '${m['relevance_level'] ?? 'core'}' == 'supplementary' ? 'supplementary' : 'core',
      rationale: '${m['rationale'] ?? ''}',
      observability: groupCode == 'C3' && rawObs == 'static_item' ? 'process_required' : rawObs,
    );
  }

  final String id;
  final String questionId;
  final String foundationId;
  final String code;
  final String groupCode;
  final String groupTitle;
  final String title;

  /// 'core'(핵심) | 'supplementary'(보조)
  final String relevanceLevel;
  final String rationale;

  /// 'static_item'(정적 문항에서 관찰 가능) | 'process_required'(풀이 과정 필요) | 'class_activity'(수업 활동 필요)
  final String observability;

  String get relevanceLabel => relevanceLevel == 'supplementary' ? '보조' : '핵심';

  String get observabilityLabel => switch (observability) {
        'static_item' => '정적 문항 관찰 가능',
        'class_activity' => '수업 활동 필요',
        _ => '풀이 과정 필요',
      };

  QuestionFoundationLink copyWith({
    String? relevanceLevel,
    String? rationale,
    String? observability,
  }) {
    final nextObs = observability ?? this.observability;
    return QuestionFoundationLink(
      id: id,
      questionId: questionId,
      foundationId: foundationId,
      code: code,
      groupCode: groupCode,
      groupTitle: groupTitle,
      title: title,
      relevanceLevel: relevanceLevel ?? this.relevanceLevel,
      rationale: rationale ?? this.rationale,
      observability: groupCode == 'C3' && nextObs == 'static_item' ? 'process_required' : nextObs,
    );
  }

  Map<String, dynamic> toPayload() => {
        'foundation_id': foundationId,
        'relevance_level': relevanceLevel,
        'rationale': rationale.trim(),
        'observability': groupCode == 'C3' && observability == 'static_item' ? 'process_required' : observability,
      };
}

class StudentFoundationObservation {
  const StudentFoundationObservation({
    required this.id,
    required this.academyId,
    required this.studentId,
    required this.foundationId,
    required this.foundationCode,
    required this.groupCode,
    required this.groupTitle,
    required this.foundationTitle,
    this.questionId,
    this.cropId,
    this.attemptId,
    required this.observationContext,
    required this.observationResult,
    required this.abPrerequisiteCheck,
    required this.evidence,
    required this.observedAt,
    this.observerId,
  });

  factory StudentFoundationObservation.fromJson(Map<String, dynamic> m) {
    String? optStr(Object? v) {
      final s = '${v ?? ''}'.trim();
      return s.isEmpty ? null : s;
    }

    return StudentFoundationObservation(
      id: '${m['id'] ?? ''}',
      academyId: '${m['academy_id'] ?? ''}',
      studentId: '${m['student_id'] ?? ''}',
      foundationId: '${m['foundation_id'] ?? ''}',
      foundationCode: '${m['foundation_code'] ?? ''}',
      groupCode: '${m['group_code'] ?? ''}',
      groupTitle: '${m['group_title'] ?? ''}',
      foundationTitle: '${m['foundation_title'] ?? ''}',
      questionId: optStr(m['question_id']),
      cropId: optStr(m['crop_id']),
      attemptId: optStr(m['attempt_id']),
      observationContext: '${m['observation_context'] ?? 'problem_solving'}',
      observationResult: '${m['observation_result'] ?? 'insufficient'}',
      abPrerequisiteCheck: '${m['ab_prerequisite_check'] ?? 'not_checked'}',
      evidence: '${m['evidence'] ?? ''}',
      observedAt: DateTime.tryParse('${m['observed_at'] ?? ''}') ?? DateTime.now(),
      observerId: optStr(m['observer_id']),
    );
  }

  final String id;
  final String academyId;
  final String studentId;
  final String foundationId;
  final String foundationCode;
  final String groupCode;
  final String groupTitle;
  final String foundationTitle;
  final String? questionId;
  final String? cropId;
  final String? attemptId;
  final String observationContext;
  final String observationResult;
  final String abPrerequisiteCheck;
  final String evidence;
  final DateTime observedAt;
  final String? observerId;
}

class ThinkingFoundationService {
  ThinkingFoundationService({SupabaseClient? client}) : _db = client ?? Supabase.instance.client;

  final SupabaseClient _db;

  Future<List<ThinkingFoundationItem>> fetchAll() async {
    final res = await _db.rpc('thinking_foundation_overview');
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    return [
      for (final r in (map['items'] as List?) ?? const [])
        if (r is Map) ThinkingFoundationItem.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  Future<void> save({
    String? id,
    required String code,
    required String groupCode,
    required String title,
    required String definition,
    required List<String> learningGoals,
    required String teachingPrinciple,
    required String observationCriteria,
    required List<String> keywords,
    required List<ThinkingFoundationExample> examples,
    required int sortOrder,
    required bool isActive,
  }) async {
    await _db.rpc('thinking_foundation_save', params: {
      'p_id': id,
      'p_code': code,
      'p_group_code': groupCode,
      'p_title': title,
      'p_definition': definition,
      'p_learning_goals': learningGoals,
      'p_teaching_principle': teachingPrinciple,
      'p_observation_criteria': observationCriteria,
      'p_keywords': keywords,
      'p_examples': [for (final ex in examples) ex.toPayload()],
      'p_sort_order': sortOrder,
      'p_is_active': isActive,
    });
  }

  Future<void> delete(String id) async {
    await _db.rpc('thinking_foundation_delete', params: {'p_id': id});
  }

  Future<Map<String, List<QuestionFoundationLink>>> fetchQuestionLinks(List<String> questionIds) async {
    final cleanIds = [
      for (final id in questionIds)
        if (id.trim().isNotEmpty) id.trim(),
    ];
    if (cleanIds.isEmpty) return const {};
    final res = await _db.rpc('pb_question_foundation_links_list', params: {
      'p_question_ids': cleanIds,
    });
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    final out = <String, List<QuestionFoundationLink>>{};
    for (final r in (map['items'] as List?) ?? const []) {
      if (r is! Map) continue;
      final item = QuestionFoundationLink.fromJson(Map<String, dynamic>.from(r));
      if (item.questionId.isEmpty) continue;
      (out[item.questionId] ??= <QuestionFoundationLink>[]).add(item);
    }
    return out;
  }

  Future<List<QuestionFoundationLink>> saveQuestionLinks(
    String questionId,
    List<QuestionFoundationLink> links,
  ) async {
    final res = await _db.rpc('pb_question_foundation_links_set', params: {
      'p_question_id': questionId,
      'p_links': [for (final l in links) l.toPayload()],
    });
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    return [
      for (final r in (map['items'] as List?) ?? const [])
        if (r is Map) QuestionFoundationLink.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  Future<void> setReviewFoundations(
    String cropId,
    List<QuestionFoundationLink> links, {
    String source = 'owner',
  }) async {
    await _db.rpc('textbook_review_set_foundations', params: {
      'p_crop_id': cropId,
      'p_links': [for (final l in links) l.toPayload()],
      'p_source': source,
    });
  }

  Future<StudentFoundationObservation> logStudentObservation({
    required String academyId,
    required String studentId,
    required String foundationId,
    required String observationResult,
    String observationContext = 'problem_solving',
    String evidence = '',
    String abPrerequisiteCheck = 'not_checked',
    String? questionId,
    String? cropId,
    String? attemptId,
    DateTime? observedAt,
  }) async {
    final res = await _db.rpc('learning_log_foundation_observation', params: {
      'p_academy_id': academyId,
      'p_student_id': studentId,
      'p_foundation_id': foundationId,
      'p_observation_result': observationResult,
      'p_observation_context': observationContext,
      'p_evidence': evidence,
      'p_ab_prerequisite_check': abPrerequisiteCheck,
      'p_question_id': questionId,
      'p_crop_id': cropId,
      'p_attempt_id': attemptId,
      'p_observed_at': observedAt?.toUtc().toIso8601String(),
    });
    return StudentFoundationObservation.fromJson(
      res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{},
    );
  }

  Future<List<StudentFoundationObservation>> fetchStudentObservations({
    required String academyId,
    required String studentId,
    String? foundationId,
    int limit = 50,
  }) async {
    final res = await _db.rpc('student_foundation_observations_recent', params: {
      'p_academy_id': academyId,
      'p_student_id': studentId,
      'p_foundation_id': foundationId,
      'p_limit': limit,
    });
    final map = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
    return [
      for (final r in (map['items'] as List?) ?? const [])
        if (r is Map) StudentFoundationObservation.fromJson(Map<String, dynamic>.from(r)),
    ];
  }
}
