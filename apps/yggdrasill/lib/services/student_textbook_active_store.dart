import 'package:supabase_flutter/supabase_flutter.dart';

import 'tenant_service.dart';

/// 학생별 플로우-교재 활성 상태의 명시적 override 저장소.
///
/// 행이 없으면 화면에서 계산한 기본값(현재 과정 이전 교재는 비활성)을 사용한다.
class StudentTextbookActiveStore {
  StudentTextbookActiveStore._();

  static final StudentTextbookActiveStore instance =
      StudentTextbookActiveStore._();

  String key({
    required String flowId,
    required String bookId,
    required String gradeLabel,
  }) =>
      '$flowId|$bookId|$gradeLabel';

  Future<Map<String, bool>> loadForStudent(String studentId) async {
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    final rows = await Supabase.instance.client
        .from('student_textbook_link_preferences')
        .select('flow_id,book_id,grade_label,enabled')
        .eq('academy_id', academyId)
        .eq('student_id', studentId);

    return <String, bool>{
      for (final raw in (rows as List<dynamic>))
        if (raw is Map)
          key(
            flowId: (raw['flow_id'] as String?) ?? '',
            bookId: (raw['book_id'] as String?) ?? '',
            gradeLabel: (raw['grade_label'] as String?) ?? '',
          ): (raw['enabled'] as bool?) ?? true,
    };
  }

  Future<void> setEnabled({
    required String studentId,
    required String flowId,
    required String bookId,
    required String gradeLabel,
    required bool enabled,
  }) async {
    final academyId = await TenantService.instance.getActiveAcademyId() ??
        await TenantService.instance.ensureActiveAcademy();
    await Supabase.instance.client
        .from('student_textbook_link_preferences')
        .upsert(
      {
        'academy_id': academyId,
        'student_id': studentId,
        'flow_id': flowId,
        'book_id': bookId,
        'grade_label': gradeLabel,
        'enabled': enabled,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'academy_id,student_id,flow_id,book_id,grade_label',
    );
  }
}
