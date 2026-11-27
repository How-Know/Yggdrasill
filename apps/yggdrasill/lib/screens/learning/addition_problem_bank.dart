import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../services/tenant_service.dart';
import 'models/problem_bank_export_models.dart';

/// 생성된 덧셈 문항을 기존 과제형 템플릿 프리셋으로 등록한다.
/// 배치는 2단, 문항 수는 많이(한 단에 들어가는 만큼)이다.
Future<String?> publishAdditionAssignmentPreset({
  required String title,
  required String content,
}) async {
  final expressions = _expressions(content);
  if (expressions.isEmpty) return null;
  final client = Supabase.instance.client;
  final academyId = ((await TenantService.instance.getActiveAcademyId()) ??
          await TenantService.instance.ensureActiveAcademy())
      .trim();
  if (academyId.isEmpty) return null;
  final userId = client.auth.currentUser?.id;
  const uuid = Uuid();
  final documentId = uuid.v4();
  final now = DateTime.now().toUtc().toIso8601String();
  await client.from('pb_documents').insert(<String, dynamic>{
    'id': documentId,
    'academy_id': academyId,
    'created_by': userId,
    'source_filename': title,
    'source_storage_bucket': 'problem-documents',
    'source_storage_path': 'generated/natural-addition/$documentId.json',
    'status': 'ready',
    // ready 문서는 curriculum_code가 비어 있으면 저장이 거절된다.
    'curriculum_code': 'rev_2022',
    'source_type_code': 'original_item',
    'material_name': '자연수 덧셈',
    'meta': <String, dynamic>{'kind': 'natural_addition_v3'},
    'created_at': now,
    'updated_at': now,
  });

  final questionRows = <Map<String, dynamic>>[];
  final questionIds = <String>[];
  final uids = <String>[];
  for (var i = 0; i < expressions.length; i++) {
    final id = uuid.v4();
    final uid = uuid.v4();
    questionIds.add(id);
    uids.add(uid);
    final expr = expressions[i];
    questionRows.add(<String, dynamic>{
      'id': id,
      'question_uid': uid,
      'academy_id': academyId,
      'document_id': documentId,
      'source_page': 1,
      'source_order': i + 1,
      'question_number': '${i + 1}',
      'question_type': '주관식',
      'stem': '\$$expr=\$',
      'is_published': true,
      'is_checked': true,
      'curriculum_code': 'rev_2022',
      'source_type_code': 'original_item',
      'material_name': '자연수 덧셈',
      'created_at': now,
      'updated_at': now,
    });
  }
  await client.from('pb_questions').insert(questionRows);

  final mode = questionModeToValue('주관식');
  final modeByUid = {for (final uid in uids) uid: mode};
  final settings = LearningProblemExportSettings(
    templateLabel: '과제형',
    paperLabel: 'A4',
    questionModeLabel: '주관식',
    layoutColumnLabel: '2단',
    maxQuestionsPerPageLabel: '많이',
    fontFamilyLabel: 'KoPubWorldBatangPro',
    fontSizeLabel: '기본',
    layoutTuning: LearningProblemLayoutTuning.defaults(),
    figureQuality: LearningProblemFigureQuality.defaults(),
    includeAnswerSheet: false,
    includeExplanation: false,
    includeAcademyLogo: true,
    timeLimitText: '',
    titlePageTopText: title,
    titlePageGoalText: '',
    includeQuestionScore: false,
    questionScoreByQuestionId: const <String, double>{},
  );
  final renderConfig = settings.toRenderConfig(
    selectedQuestionUidsOrdered: uids,
    questionModeByQuestionUid: modeByUid,
  );
  renderConfig['titlePageTopText'] = title;
  renderConfig['titlePageGoalText'] = '';
  renderConfig['includeCoverPage'] = false;
  renderConfig['templateProfile'] = 'assignment';
  renderConfig['layoutColumns'] = 2;
  renderConfig['maxQuestionsPerPage'] = 99;

  final preset = await client
      .from('pb_export_presets')
      .insert(<String, dynamic>{
        'academy_id': academyId,
        'source_document_id': documentId,
        'document_id': documentId,
        'display_name': title,
        'preset_kind': 'assignment',
        'render_config': renderConfig,
        'source_document_ids': <String>[documentId],
        'selected_question_uids': uids,
        'selected_question_ids': questionIds,
        'question_mode_by_question_uid': modeByUid,
        'question_mode_by_question_id': modeByUid,
        'created_by': userId,
        'created_at': now,
        'updated_at': now,
      })
      .select('id')
      .single();
  final presetId = '${preset['id'] ?? ''}'.trim();
  return presetId.isEmpty ? null : presetId;
}

List<String> _expressions(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is! Map || decoded['kind'] != 'natural_addition_v3') return const [];
    final items = decoded['items'];
    if (items is! List) return const [];
    return [
      for (final row in items)
        if (row is Map && '${row['expr'] ?? ''}'.trim().isNotEmpty) '${row['expr']}'.trim(),
    ];
  } catch (_) {
    return const [];
  }
}
