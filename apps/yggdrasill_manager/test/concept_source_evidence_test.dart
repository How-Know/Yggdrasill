import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_source_evidence_view.dart';
import 'package:yggdrasill_manager/services/concept_library_service.dart';
import 'package:yggdrasill_manager/services/concept_source_evidence.dart';
import 'package:yggdrasill_manager/services/concept_statement_service.dart';
import 'package:yggdrasill_manager/services/concept_statement_store.dart';

const _concept = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b';

Map<String, dynamic> _row(String id,
        {String? statement, String scope = 'unknown', String? setAt, bool blocks = true}) =>
    {
      'id': id,
      'statement_id': statement,
      'book_name': '개념+유형',
      'grade_label': '1-1',
      'raw_page': 8,
      'evidence_scope': scope,
      'evidence_note': null,
      'evidence_origin': setAt == null ? null : 'owner',
      'evidence_set_at': setAt,
      'basis_changed': false,
      'draft_id': blocks ? 'd1' : null,
      'draft_found': blocks,
      'blocks': blocks
          ? [
              {'id': 'p8-a0', 'raw_page': 8, 'kind': 'concept_box', 'title': '소수', 'text': '1과 자기 자신만을 약수로 가지는 수'},
            ]
          : [],
    };

/// RPC와 같은 규칙(본 시각이 다르면 막음, AI 제안은 서술 글 md5가 같아야 함)을 흉내 낸다.
class _Fake implements ConceptEvidenceBackend {
  final Map<String, Map<String, dynamic>> rows = {
    's1': _row('s1'),
    's2': _row('s2', blocks: false),
  };
  String md5 = 'm1';
  final List<String> writes = [];
  ConceptEvidenceProposal? next;
  Object? proposeError;
  int _tick = 0;

  @override
  Future<ConceptEvidenceSnapshot> load(String conceptId) async => ConceptEvidenceSnapshot.fromJson({
        'groups': [
          {'statement_id': null, 'kind': 'base', 'text': '본문', 'md5': md5},
        ],
        'sources': rows.values.toList(),
      });

  @override
  Future<void> setScope(ConceptSourceEvidence current,
      {required ConceptEvidenceScope scope, String? note, String origin = 'owner', String? basisMd5}) async {
    final r = rows[current.sourceId]!;
    if (r['evidence_set_at'] != current.setAtRaw) {
      throw ConceptEvidenceException(
          'concept_source_evidence_stale', ConceptEvidenceException.messageOf('concept_source_evidence_stale'));
    }
    if (origin == 'ai' && basisMd5 != md5) {
      throw ConceptEvidenceException(
          'concept_source_basis_changed', ConceptEvidenceException.messageOf('concept_source_basis_changed'));
    }
    writes.add('${current.sourceId}:${scope.db}:$origin:${note ?? ''}');
    r
      ..['evidence_scope'] = scope.db
      ..['evidence_note'] = note
      ..['evidence_origin'] = origin
      ..['evidence_set_at'] = '2026-10-20T10:00:0${++_tick}.123456+00:00';
  }

  @override
  Future<ConceptEvidenceProposal> propose(String conceptId, String? statementId) async {
    if (proposeError != null) throw proposeError!;
    return next!;
  }
}

ConceptEvidenceProposal _proposal({String md5 = 'm1'}) => ConceptEvidenceProposal.fromJson(null, {
      'summary': '정의는 있고 조건은 없음',
      'basis_md5': md5,
      'items': [
        {
          'source_id': 's1',
          'scope': 'part',
          'current_scope': 'unknown',
          'reason': '조건이 없음',
          'covered': '정의',
          'missing': '조건'
        },
      ],
      'checks': {
        'no_blocks': ['s2'],
        'unanswered': [],
      },
    });

class _NoStatements implements ConceptStatementBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

ConceptSourceRef _source(String id) => ConceptSourceRef(
      id: id,
      conceptId: _concept,
      academyId: 'a',
      bookId: 'b',
      gradeLabel: '1-1',
      rawPage: 8,
      bookName: '개념+유형',
    );

void main() {
  group('근거 상태', () {
    test('기존 출처는 범위 미확인이고, 운영자가 정하면 본 시각을 돌려주며 다시 읽는다', () async {
      final fake = _Fake();
      final ev = ConceptEvidenceController(fake, _concept);
      await ev.load();
      expect(ev.of('s1')!.scope, ConceptEvidenceScope.unknown);
      expect(ev.of('s1')!.blocks.single.text, contains('약수'));
      expect(ev.of('s2')!.blocks, isEmpty);

      expect(await ev.setScope(ev.of('s1')!, ConceptEvidenceScope.whole, '정의 전체'), isNull);
      expect(fake.writes, ['s1:whole:owner:정의 전체']);
      expect(ev.of('s1')!.scope, ConceptEvidenceScope.whole);
      expect(ev.of('s1')!.origin, 'owner');

      final stale = ev.of('s1')!;
      fake.rows['s1']!['evidence_set_at'] = '2026-10-20T11:00:00+00:00';
      expect(await ev.setScope(stale, ConceptEvidenceScope.part, null), contains('그사이'));
      expect(fake.writes, hasLength(1));
      expect(ev.of('s1')!.setAtRaw, '2026-10-20T11:00:00+00:00', reason: '실패하면 최신 값을 다시 읽는다');
    });

    test('AI 제안은 받아들인 줄만 저장되고, 버리면 아무것도 저장하지 않으며, 서술이 바뀌었으면 막고 제안을 지운다', () async {
      final fake = _Fake()..next = _proposal();
      final ev = ConceptEvidenceController(fake, _concept);
      await ev.load();
      await ev.propose(null);
      final p = ev.proposalFor(null)!;
      expect(p.noBlocks, ['s2']);
      expect(ev.proposalItem('s1')!.scope, ConceptEvidenceScope.part);
      expect(fake.writes, isEmpty, reason: '제안만으로는 저장하지 않는다');

      ev.reject(p, p.items.single);
      expect(ev.proposalFor(null), isNull);
      expect(fake.writes, isEmpty);

      await ev.propose(null);
      expect(await ev.accept(ev.proposalFor(null)!, ev.proposalItem('s1')!), isNull);
      expect(fake.writes, ['s1:part:ai:']);
      expect(ev.of('s1')!.origin, 'ai');
      expect(ev.proposalItem('s1'), isNull);

      fake.next = _proposal(md5: 'old');
      await ev.propose(null);
      expect(await ev.accept(ev.proposalFor(null)!, ev.proposalItem('s1')!), contains('서술이 바뀌어'));
      expect(fake.writes, hasLength(1));
      expect(ev.proposalFor(null), isNull);
    });

    test('제안을 받지 못하면 이유를 보이고, 저장소가 없으면 준비 전으로 본다', () async {
      final fake = _Fake()
        ..proposeError =
            ConceptEvidenceException('no_evidence_blocks', ConceptEvidenceException.messageOf('no_evidence_blocks'));
      final ev = ConceptEvidenceController(fake, _concept);
      await ev.propose(null);
      expect(ev.proposeErrors[null], contains('근거 블록이 없어'));

      final none = ConceptEvidenceController(const ConceptEvidenceUnavailable(), _concept);
      await none.load();
      expect(none.notReady, isTrue);
      expect(none.snapshot, isNull);
    });

    test('출처를 더하거나 빼거나 다른 서술로 옮기면 다시 읽을 대상이다', () {
      final snap = ConceptEvidenceSnapshot.fromJson({
        'sources': [_row('s1'), _row('s2', statement: 'st')],
      });
      final list = [_source('s1'), _source('s2')];
      expect(conceptEvidenceOutOfDate(snap, list, (s) => s.id == 's2' ? 'st' : null), isFalse);
      expect(conceptEvidenceOutOfDate(snap, list, (s) => null), isTrue);
      expect(conceptEvidenceOutOfDate(snap, list, null), isFalse, reason: '서술을 못 읽었으면 id만 본다');
      expect(conceptEvidenceOutOfDate(snap, [_source('s1')], null), isTrue);
      expect(conceptEvidenceOutOfDate(null, list, null), isFalse);
    });
  });

  group('출처 창 근거 줄', () {
    Future<(_Fake, ConceptEvidenceController)> pump(WidgetTester tester) async {
      final fake = _Fake()..next = _proposal();
      final ev = ConceptEvidenceController(fake, _concept);
      await ev.load();
      final store = ConceptStatementStore(() => _NoStatements());
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: ev,
            builder: (context, _) => SingleChildScrollView(
              child: Column(
                children: [
                  ConceptEvidenceProposeBar(evidence: ev, statements: store, conceptId: _concept),
                  for (final id in ['s1', 's2'])
                    ConceptSourceEvidenceLine(evidence: ev, source: _source(id), sourceLabel: '개념+유형 · 1-1 · PDF 8쪽'),
                ],
              ),
            ),
          ),
        ),
      ));
      return (fake, ev);
    }

    testWidgets('범위 배지·근거 문장(원문 표시)·근거 없는 출처 안내가 보이고, 직접 정하면 저장된다', (tester) async {
      final (fake, _) = await pump(tester);
      expect(find.text('근거 범위: 범위 미확인'), findsNWidgets(2));
      expect(find.textContaining('이어진 근거 블록이 없습니다'), findsOneWidget);
      expect(find.byKey(const ValueKey('evidence-blocks-s2')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('evidence-blocks-s1')));
      await tester.pump();
      expect(find.textContaining('정리한 서술이 아닙니다'), findsOneWidget);
      expect(find.textContaining('자기 자신만을 약수로', findRichText: true), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('evidence-edit-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('evidence-pick-related')));
      await tester.enterText(find.byKey(const ValueKey('evidence-note')), '예제만 있음');
      await tester.tap(find.byKey(const ValueKey('evidence-scope-save')));
      await tester.pumpAndSettle();
      expect(fake.writes, ['s1:related:owner:예제만 있음']);
      expect(find.text('근거 범위: 관련 설명'), findsOneWidget);
      expect(find.text('범위 메모: 예제만 있음'), findsOneWidget);
    });

    testWidgets('AI 제안을 받으면 줄마다 보이고, 받아들인 줄만 저장된다', (tester) async {
      final (fake, _) = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('evidence-propose-base')));
      await tester.pumpAndSettle();
      expect(find.textContaining('받아들인 줄만 저장'), findsOneWidget);
      expect(find.textContaining('근거 블록이 없어 보내지 않은 출처 1개'), findsOneWidget);
      expect(find.text('AI 제안: 일부 근거 (지금 범위 미확인)'), findsOneWidget);
      expect(find.text('근거에 없는 부분: 조건'), findsOneWidget);
      expect(fake.writes, isEmpty);

      await tester.tap(find.byKey(const ValueKey('evidence-accept-s1')));
      await tester.pumpAndSettle();
      expect(fake.writes, ['s1:part:ai:']);
      expect(find.text('근거 범위: 일부 근거'), findsOneWidget);
      expect(find.text('AI 제안 승인'), findsOneWidget);
      expect(find.byKey(const ValueKey('evidence-proposal-s1')), findsNothing);
    });
  });
}
