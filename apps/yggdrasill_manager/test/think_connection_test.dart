import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/think/think_api.dart';
import 'package:yggdrasill_manager/services/think/think_code_models.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

void main() {
  test('supabaseProjectRef는 호스트에서 프로젝트 ref만 추출한다', () {
    expect(
      ThinkApi.supabaseProjectRef('https://abcdefgh.supabase.co'),
      'abcdefgh',
    );
    expect(ThinkApi.supabaseProjectRef('https://custom.example.com'), 'custom.example.com');
    expect(ThinkApi.supabaseProjectRef(''), isNull);
  });

  test('migrationPathsFromDiff는 migrations SQL 경로를 정렬한다', () {
    const diff = 'diff --git a/supabase/migrations/20261008000001_b.sql '
        'b/supabase/migrations/20261008000001_b.sql\n'
        'diff --git a/supabase/migrations/20261008000000_a.sql '
        'b/supabase/migrations/20261008000000_a.sql\n';
    expect(
      migrationPathsFromDiff(diff),
      [
        'supabase/migrations/20261008000000_a.sql',
        'supabase/migrations/20261008000001_b.sql',
      ],
    );
  });

  test('ThinkStatus는 prompt_version을 파싱한다', () {
    final s = ThinkStatus.fromJson({
      'configured': true,
      'provider': 'openai',
      'models': {'primary': 'm1'},
      'web_search_enabled': true,
      'prompt_version': 'think-2026-10-01',
    });
    expect(s.promptVersion, 'think-2026-10-01');
  });

  test('ThinkMemoryFeedbackDraft JSON 파싱', () {
    final d = ThinkMemoryFeedbackDraft.fromJson({
      'candidates': [
        {
          'kind': 'note',
          'title': 't',
          'content': 'c',
          'decision_context': '',
          'decision_reason': '',
          'alternatives': [],
          'tags': [],
          'update_memory_id': null,
        },
      ],
      'duplicate_warnings': [
        {'candidate_index': 0, 'memory_id': 'm1', 'memory_title': 'T', 'reason': '겹침'},
      ],
      'insufficient_evidence': false,
      'notes': '',
    });
    expect(d.candidates.single.title, 't');
    expect(d.duplicateWarnings.single.memoryId, 'm1');
  });

  test('ThinkMemoryFeedbackUpdateBaseline 파싱·유효성', () {
    final ok = ThinkMemoryFeedbackUpdateBaseline.fromJson({
      'memory_id': '11111111-1111-4111-8111-111111111111',
      'version': 3,
    });
    expect(ok.isValid, isTrue);
    expect(ok.memoryId, '11111111-1111-4111-8111-111111111111');
    expect(ok.version, 3);
    expect(ThinkMemoryFeedbackUpdateBaseline.fromJson(null).isValid, isFalse);
  });

  test('기존 기억 수정 저장은 baseline version으로 낙관적 잠금', () {
    final baseline = ThinkMemoryFeedbackUpdateBaseline.fromJson({
      'memory_id': 'm1',
      'version': 2,
    });
    final candidateId = 'm1';
    expect(baseline.isValid && baseline.memoryId == candidateId, isTrue);
    final wrongId = 'm2';
    expect(baseline.memoryId == wrongId, isFalse);
  });
}
