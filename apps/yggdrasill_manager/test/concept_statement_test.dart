import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yggdrasill_manager/services/concept_statement_service.dart';

void main() {
  group('서술 읽기', () {
    test('확정본과 저장된 초안을 따로 읽고, 편집은 초안에서 시작한다', () {
      final s = ConceptStatement.fromRow({
        'id': 's1',
        'concept_id': 'c1',
        'role': 'statement',
        'sort_order': 1,
        'version': 2,
        'content': {
          'title': '표본공간으로 본 확률',
          'body': r'$P(A)=\frac{n(A)}{n(S)}$',
          'approach': '집합과 기호',
          'conditions_in_source': 'stated',
          'terms': ['표본공간', '근원사건'],
          'basis': 'organized',
        },
        'confirmed_at': '2026-10-20T01:00:00.123456+00:00',
        'draft': {'title': '표본공간으로 본 확률', 'body': '고친 본문', 'basis': 'verbatim', 'quote': '원문'},
        'draft_origin': 'owner',
        'draft_saved_at': '2026-10-20T02:00:00.654321+00:00',
      });
      expect(s.role, ConceptStatementRole.statement);
      expect(s.confirmed, isTrue);
      expect(s.hasDraft, isTrue);
      expect(s.statusLabel, '확정 v2 · 저장된 초안 있음');
      expect(s.content!.approach, '집합과 기호');
      expect(s.content!.conditionsInSource, ConceptConditionsInSource.stated);
      expect(s.content!.terms, ['표본공간', '근원사건']);
      expect(s.saved.body, '고친 본문');
      expect(s.saved.basis, ConceptStatementBasis.verbatim);
      expect(s.draftSavedAtRaw, '2026-10-20T02:00:00.654321+00:00', reason: '서버 시각을 마이크로초까지 그대로 돌려보낸다');
    });

    test('확정 전 초안과 공통 내용', () {
      final draft = ConceptStatement.fromRow({
        'id': 's2',
        'concept_id': 'c1',
        'role': 'statement',
        'version': 0,
        'draft': {'title': 'A', 'body': 'B'},
        'draft_origin': 'owner',
        'draft_saved_at': '2026-10-20T02:00:00+00:00',
      });
      expect(draft.statusLabel, '확정 전 초안');
      expect(draft.content, isNull);
      expect(draft.saved.basis, ConceptStatementBasis.organized, reason: '기록이 없으면 우리가 정리한 글');

      final core = ConceptStatement.fromRow({
        'id': 'k1',
        'concept_id': 'c1',
        'role': 'core',
        'version': 1,
        'content': {'meaning': '공통 의미', 'conditions': '유한, 등가능'},
        'confirmed_at': '2026-10-20T01:00:00+00:00',
      });
      expect(core.role, ConceptStatementRole.core);
      expect(core.role.label, '개념 공통 내용');
      expect(core.saved.meaning, '공통 의미');
      expect(core.statusLabel, '확정 v1');
    });
  });

  group('서술 보내기', () {
    test('서술은 서술 칸만, 빈 칸은 빼고, 용어는 다듬어 한 번씩 보낸다', () {
      const text = ConceptStatementText(
        title: ' 경우의 수로 본 확률 ',
        body: '본문',
        approach: '  ',
        conditions: '가능성이 같다',
        conditionsInSource: ConceptConditionsInSource.checkContext,
        terms: ['사건', ' 사건 ', '', '경우의 수'],
        meaning: '보내지 않음',
      );
      expect(text.toJson(ConceptStatementRole.statement), {
        'title': '경우의 수로 본 확률',
        'body': '본문',
        'conditions': '가능성이 같다',
        'conditions_in_source': 'check_context',
        'terms': ['사건', '경우의 수'],
        'basis': 'organized',
      });
    });

    test('공통 내용은 공통 의미·범위·조건만 보낸다', () {
      const text = ConceptStatementText(title: '보내지 않음', body: '보내지 않음', meaning: '공통 의미', scope: '유한 표본공간');
      expect(text.toJson(ConceptStatementRole.core), {'meaning': '공통 의미', 'scope': '유한 표본공간'});
    });

    test('읽은 글을 그대로 다시 보내면 같은 내용이 된다', () {
      final j = {
        'title': '교재 원문',
        'body': '(사건의 경우의 수)/(모든 경우의 수)',
        'conditions_in_source': 'omitted',
        'terms': ['사건'],
        'basis': 'verbatim',
        'quote': '각 경우가 일어날 가능성이 같을 때…',
        'supplement_note': '조건을 보완함',
        'unverified_note': '단원 전제 미확인',
      };
      expect(ConceptStatementText.fromJson(j).toJson(ConceptStatementRole.statement), j);
    });
  });

  group('등장 위치·오류', () {
    test('교육과정 판을 모르면 미기록으로 보인다', () {
      final a = ConceptAppearance.fromRow({
        'id': 'a1',
        'concept_id': 'c1',
        'statement_id': null,
        'curriculum_code': null,
        'school_level': '중',
        'course_label': '2-2',
        'unit_path': ['확률'],
      });
      expect(a.label, '교육과정 판 미기록 · 중 2-2 · 확률');
      final b = ConceptAppearance.fromRow({
        'id': 'a2',
        'concept_id': 'c1',
        'statement_id': 's1',
        'curriculum_code': 'rev_2015',
        'school_level': '고',
        'course_label': '확률과 통계',
      });
      expect(b.label, '2015 개정 · 고 확률과 통계');
    });

    test('서버 오류를 알아듣는 말로 바꾸고, 반영 전이면 not_ready', () {
      final stale =
          ConceptStatementException.from(const PostgrestException(message: 'concept_statement_stale', code: 'P0001'));
      expect(stale.stale, isTrue);
      expect(stale.message, contains('최신 저장본'));
      expect(
          ConceptStatementException.from(const PostgrestException(
                  message: 'column concept_sources.statement_id does not exist', code: '42703'))
              .notReady,
          isTrue);
      expect(
          ConceptStatementException.from(
                  const PostgrestException(message: 'relation "concept_statements" does not exist', code: '42P01'))
              .notReady,
          isTrue);
      expect(
          ConceptStatementException.from(const PostgrestException(message: 'duplicate key', code: '23505'),
                  duplicate: '같은 등장 위치가 이미 있습니다.')
              .message,
          '같은 등장 위치가 이미 있습니다.');
      expect(
          ConceptStatementException.from(const PostgrestException(message: 'concept_statement_in_use', code: 'P0001'))
              .message,
          contains('출처나 등장 위치'));
    });
  });
}
