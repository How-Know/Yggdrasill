import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yggdrasill_manager/services/concept_service.dart';

void main() {
  group('붙은 자료 글', () {
    test('정해 둔 순서로 0개와 total 은 빼고 적는다. 모르는 종류도 빠뜨리지 않는다', () {
      expect(
        conceptAttachedText({'total': 6, 'type_link': 1, 'sources': 2, 'statements': 0, 'draft_refs': 1, 'new_kind': 2}),
        '출처 2 · 유형 연결 1 · 열린 교재 초안 검토의 대상 1 · new_kind 2',
      );
      expect(conceptAttachedText({'total': 0, 'sources': 0}), '');
    });
  });

  group('지우기 미리 보기', () {
    test('지울 수 있는지와 붙은 자료를 읽는다', () {
      final c = ConceptDeleteCheck.fromJson({
        'deletable': false,
        'attached': {'sources': 1, 'content_revisions': 2, 'total': 3},
      });
      expect(c.deletable, isFalse);
      expect(c.attached, {'sources': 1, 'content_revisions': 2, 'total': 3});
    });

    test('결과가 분명하지 않으면 지울 수 있다고 보지 않고 예외를 낸다', () {
      for (final raw in [
        null,
        'ok',
        {'attached': {'total': 0}},
        {'deletable': 'true', 'attached': {'total': 0}},
        {'deletable': true},
        {'deletable': true, 'attached': {'sources': 0}},
      ]) {
        expect(
          () => ConceptDeleteCheck.fromJson(raw),
          throwsA(isA<ConceptDeleteException>().having((e) => e.code, 'code', 'bad_response')),
          reason: '$raw',
        );
      }
    });
  });

  group('서버 거절 풀기', () {
    test('붙은 자료로 거절되면 종류·개수를 싣는다(detail 이 글이든 객체든)', () {
      for (final details in ['{"sources":2,"type_link":1,"total":3}', {'sources': 2, 'type_link': 1, 'total': 3}]) {
        final e = ConceptDeleteException.from(
          PostgrestException(message: 'concept_delete_attached', code: 'P0001', details: details),
        );
        expect(e.attachedBlock, isTrue);
        expect(e.attached, {'sources': 2, 'type_link': 1, 'total': 3});
        expect(e.message, contains('출처 2 · 유형 연결 1'));
      }
      final bare = ConceptDeleteException.from(
        const PostgrestException(message: 'concept_delete_attached', code: 'P0001', details: 'not json'),
      );
      expect([bare.attachedBlock, bare.attached], [true, <String, int>{}]);
      expect(bare.message, '붙은 자료가 있어 지우지 않았습니다.');
    });

    test('폴더에 개념이 있으면 개수를 알린다', () {
      final e = ConceptDeleteException.from(
        const PostgrestException(message: 'concept_folder_not_empty', code: 'P0001', details: '{"concepts":3}'),
      );
      expect(e.code, 'concept_folder_not_empty');
      expect(e.attached, {'concepts': 3});
      expect(e.message, contains('개념 3개'));
    });

    test('권한·없음·서버 준비 전·그 밖의 오류를 구분한다', () {
      String codeOf(PostgrestException p) => ConceptDeleteException.from(p).code;
      expect(codeOf(const PostgrestException(message: 'concept_delete_forbidden', code: 'P0001')), 'concept_delete_forbidden');
      expect(codeOf(const PostgrestException(message: 'concept_delete_not_found', code: 'P0001')), 'concept_delete_not_found');
      expect(codeOf(const PostgrestException(message: 'Could not find the function', code: 'PGRST202')), 'not_ready');
      expect(codeOf(const PostgrestException(message: 'permission denied', code: '42501')), 'denied');
      expect(codeOf(const PostgrestException(message: 'boom', code: 'XX000')), 'XX000');
      expect(ConceptDeleteException.from(StateError('network')).code, 'error');
    });
  });
}
