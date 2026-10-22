import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_library_pane.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_type_chip.dart';
import 'package:yggdrasill_manager/services/concept_library_controller.dart';
import 'package:yggdrasill_manager/services/concept_library_service.dart';
import 'package:yggdrasill_manager/services/concept_service.dart';
import 'package:yggdrasill_manager/services/concept_statement_service.dart';
import 'package:yggdrasill_manager/services/concept_statement_store.dart';
import 'package:yggdrasill_manager/services/concept_topic.dart';
import 'package:yggdrasill_manager/services/think/think_concept_chat_controller.dart';
import 'package:yggdrasill_manager/services/think/think_send_lock.dart';

const _concept = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b';
const _src1 = 's0000000-0000-4000-8000-000000000001';
const _src2 = 's0000000-0000-4000-8000-000000000002';

ConceptItem _item() => ConceptItem(
      id: _concept,
      kind: ConceptKind.definition,
      name: '확률',
      content: r'사건 $A$가 일어나는 경우의 수를 모든 경우의 수로 나눈 값',
    );

ConceptSourceRef _source(String id, int page) => ConceptSourceRef(
      id: id,
      conceptId: _concept,
      academyId: 'a',
      bookId: 'b',
      gradeLabel: '고1',
      rawPage: page,
      bookName: '수학 개념서',
    );

/// RPC와 같은 규칙(판·초안 저장 시각이 다르면 막음, 확정본과 같으면 초안 비움, 확정 전 서술은 버리면 지움)을 흉내 낸다.
class _MemStatements implements ConceptStatementBackend {
  final Map<String, ConceptStatement> rows = {};
  final Map<String, List<ConceptStatementRevision>> revs = {};
  final Map<String, String?> sourceOf = {};
  final List<ConceptAppearance> appearances = [];
  int writes = 0;
  int _seq = 0;
  int _tick = 0;

  String _key(ConceptStatementText? t, ConceptStatementRole role) => t == null ? '' : jsonEncode(t.toJson(role));
  ConceptStatementText _clean(ConceptStatementText t, ConceptStatementRole role) =>
      ConceptStatementText.fromJson(t.toJson(role));

  void _check(ConceptStatement base) {
    final now = rows[base.id];
    if (now == null) throw ConceptStatementException('concept_statement_not_found', '없음');
    if (now.version != base.version || now.draftSavedAtRaw != base.draftSavedAtRaw) {
      throw ConceptStatementException('concept_statement_stale', '그사이 바뀜');
    }
  }

  ConceptStatement _with(ConceptStatement s,
          {int? version, ConceptStatementText? content, ConceptStatementText? draft, bool clearDraft = false}) =>
      ConceptStatement(
        id: s.id,
        conceptId: s.conceptId,
        role: s.role,
        sortOrder: s.sortOrder,
        version: version ?? s.version,
        content: content ?? s.content,
        draft: clearDraft ? null : (draft ?? s.draft),
        draftOrigin: clearDraft ? null : 'owner',
        draftSavedAtRaw: clearDraft ? null : 't${++_tick}',
      );

  /// 다른 곳에서 초안을 고친 것처럼 저장 시각만 바꾼다.
  void touchElsewhere(String id) {
    final s = rows[id]!;
    rows[id] = _with(s, draft: s.draft ?? s.content);
  }

  @override
  Future<List<ConceptStatement>> statementsFor(String conceptId) async {
    final list = [
      for (final s in rows.values)
        if (s.conceptId == conceptId) s
    ];
    list.sort((a, b) => a.role.index.compareTo(b.role.index));
    return list;
  }

  @override
  Future<ConceptStatement> create({
    required String conceptId,
    required ConceptStatementRole role,
    required ConceptStatementText text,
  }) async {
    writes += 1;
    if (role == ConceptStatementRole.statement && text.title.trim().isEmpty) {
      throw ConceptStatementException('concept_statement_title_required', '서술 제목을 입력하세요.');
    }
    final row = ConceptStatement(
      id: 'st-${++_seq}',
      conceptId: conceptId,
      role: role,
      draft: _clean(text, role),
      draftOrigin: 'owner',
      draftSavedAtRaw: 't${++_tick}',
    );
    rows[row.id] = row;
    return row;
  }

  @override
  Future<ConceptStatement> saveDraft(ConceptStatement base, ConceptStatementText text) async {
    writes += 1;
    _check(base);
    final now = rows[base.id]!;
    final clean = _clean(text, now.role);
    final next = now.confirmed && _key(clean, now.role) == _key(now.content, now.role)
        ? _with(now, clearDraft: true)
        : _with(now, draft: clean);
    rows[base.id] = next;
    return next;
  }

  @override
  Future<ConceptStatement> confirm(ConceptStatement base, {String? note}) async {
    writes += 1;
    _check(base);
    final now = rows[base.id]!;
    if (now.draft == null) throw ConceptStatementException('concept_statement_no_draft', '초안 없음');
    final next = _with(now, version: now.version + 1, content: now.draft, clearDraft: true);
    rows[base.id] = next;
    (revs[base.id] ??= [])
        .insert(0, ConceptStatementRevision(version: next.version, content: next.content!, note: note));
    return next;
  }

  @override
  Future<ConceptStatement?> discardDraft(ConceptStatement base) async {
    writes += 1;
    _check(base);
    final now = rows[base.id]!;
    if (!now.confirmed) {
      rows.remove(base.id);
      return null;
    }
    final next = _with(now, clearDraft: true);
    rows[base.id] = next;
    return next;
  }

  @override
  Future<List<ConceptStatementRevision>> revisions(String statementId) async => revs[statementId] ?? [];

  @override
  Future<Map<String, String?>> sourceStatements(String conceptId) async => Map.of(sourceOf);

  @override
  Future<void> setSourceStatement({required String sourceId, String? statementId}) async {
    writes += 1;
    sourceOf[sourceId] = statementId;
  }

  @override
  Future<List<ConceptAppearance>> appearancesFor(String conceptId) async => List.of(appearances);

  @override
  Future<ConceptAppearance> addAppearance({
    required String conceptId,
    String? statementId,
    String? curriculumCode,
    required String schoolLevel,
    required String courseLabel,
    List<String> unitPath = const [],
    String? note,
  }) async {
    writes += 1;
    final dup = appearances.any((a) =>
        a.statementId == statementId &&
        a.curriculumCode == curriculumCode &&
        a.schoolLevel == schoolLevel &&
        a.courseLabel == courseLabel &&
        a.unitPath.join('>') == unitPath.join('>'));
    if (dup) throw ConceptStatementException('duplicate', '같은 등장 위치가 이미 있습니다.');
    final row = ConceptAppearance(
      id: 'ap-${++_seq}',
      conceptId: conceptId,
      statementId: statementId,
      curriculumCode: curriculumCode,
      schoolLevel: schoolLevel,
      courseLabel: courseLabel,
      unitPath: unitPath,
      note: note,
    );
    appearances.add(row);
    return row;
  }

  @override
  Future<void> removeAppearance(String id) async {
    writes += 1;
    appearances.removeWhere((a) => a.id == id);
  }

  @override
  Future<List<ConceptContentRevision>> contentRevisions(String conceptId) async => const [];

  @override
  Future<ConceptContentDraft?> contentDraft(String conceptId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _Lib implements ConceptLibraryBackend {
  final List<ConceptSourceRef> sources = [];

  @override
  Future<List<ConceptSourceRef>> sourcesFor(String conceptId) async => List.of(sources);

  @override
  Future<List<String>> criterionIdsForConcept(String conceptId) async => const [];

  @override
  Future<String?> conceptTypeName(String conceptId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

ConceptLibraryController _controller(_MemStatements mem, {_Lib? lib}) =>
    ConceptLibraryController.forTest(lib ?? _Lib(), chat: ConceptChatController.forTest(), statementBackend: mem);

Future<void> _pumpDetail(WidgetTester tester, ConceptLibraryController c) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 440,
          height: 1000,
          child: ConceptDetailView(controller: c, onEdit: (_) {}, onPickForChat: (_) {}),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThinkSendLock.instance.resetForTest();
  });

  group('서술 저장소', () {
    test('서술은 초안으로 만들고 확정은 따로 한다. 다른 서술·개념 본문은 건드리지 않는다', () async {
      final mem = _MemStatements();
      final store = ConceptStatementStore(() => mem);
      await store.load(_concept);
      expect(store.statementCountOf(_concept), 0);

      final (a, errA) = await store.create(
        _concept,
        ConceptStatementRole.statement,
        const ConceptStatementText(title: '경우의 수로 본 확률', body: '경우의 수 비율'),
      );
      expect(errA, isNull);
      expect(a!.confirmed, isFalse);
      expect(store.selectedOf(_concept), a.id, reason: '만든 서술을 고른다');
      final (b, _) = await store.create(
        _concept,
        ConceptStatementRole.statement,
        const ConceptStatementText(title: '표본공간으로 본 확률', body: r'$n(A)/n(S)$', basis: ConceptStatementBasis.verbatim),
      );
      expect(store.statementCountOf(_concept), 2);

      final (ca, _) = await store.confirm(store.byId(_concept, a.id)!);
      expect(ca!.version, 1);
      expect(store.byId(_concept, b!.id)!.confirmed, isFalse, reason: '다른 서술은 그대로');

      final (same, _) = await store.saveDraft(ca, ca.content!);
      expect(same!.hasDraft, isFalse, reason: '확정본과 같으면 초안을 비운다');
    });

    test('그사이 바뀐 서술은 저장을 막고 다시 읽는다', () async {
      final mem = _MemStatements();
      final store = ConceptStatementStore(() => mem);
      await store.load(_concept);
      final (a, _) = await store.create(
          _concept, ConceptStatementRole.statement, const ConceptStatementText(title: 'A', body: 'a'));
      mem.touchElsewhere(a!.id);

      final (row, err) = await store.saveDraft(a, const ConceptStatementText(title: 'A', body: 'b'));
      expect(row, isNull);
      expect(err, contains('바뀜'));
      expect(store.byId(_concept, a.id)!.draftSavedAtRaw, mem.rows[a.id]!.draftSavedAtRaw, reason: '최신 저장본을 다시 읽음');

      final (again, err2) =
          await store.saveDraft(store.byId(_concept, a.id)!, const ConceptStatementText(title: 'A', body: 'b'));
      expect(err2, isNull);
      expect(again!.draft!.body, 'b');
    });

    test('확정한 적 없는 서술은 초안을 버리면 지워진다', () async {
      final mem = _MemStatements();
      final store = ConceptStatementStore(() => mem);
      await store.load(_concept);
      final (a, _) = await store.create(
          _concept, ConceptStatementRole.statement, const ConceptStatementText(title: 'A', body: 'a'));
      final (row, err) = await store.discardDraft(a!);
      expect(err, isNull);
      expect(row, isNull);
      expect(store.statementsOf(_concept), isEmpty);
      expect(store.selectedOf(_concept), isNull, reason: '지운 서술을 고르고 있지 않는다');
    });

    test('트리 표시용 서술 수는 묶음을 바꿔도 남는다', () {
      const meta = ConceptTreeMeta(statementCount: {_concept: 2});
      expect(meta.withAnchors({_concept: null}).statementCount[_concept], 2);
    });
  });

  group('개념 상세 서술 칸', () {
    testWidgets('서술을 고르면 그 서술만 펼친다', (tester) async {
      final mem = _MemStatements();
      mem.rows['st-x'] = const ConceptStatement(
        id: 'st-x',
        conceptId: _concept,
        role: ConceptStatementRole.statement,
        version: 1,
        content: ConceptStatementText(
          title: '표본공간으로 본 확률',
          body: '표본공간의 원소 수로 나눈 값',
          conditions: '근원사건이 같은 정도로 기대될 때',
          conditionsInSource: ConceptConditionsInSource.stated,
          terms: ['표본공간', '근원사건'],
          quote: '원문 문장',
        ),
      );
      final c = _controller(mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);

      expect(find.text('서술 2'), findsOneWidget);
      expect(find.text('서술 2개'), findsOneWidget, reason: '머리 배지');
      expect(find.text('서술 · 기본(개념 본문)'), findsOneWidget);
      expect(find.text('근원사건이 같은 정도로 기대될 때'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('statement-pick-st-x')));
      await tester.pumpAndSettle();
      expect(find.text('서술 2/2 · 표본공간으로 본 확률'), findsOneWidget);
      expect(find.text('근원사건이 같은 정도로 기대될 때'), findsOneWidget);
      expect(find.text('원문에 조건이 적혀 있음'), findsOneWidget);
      const quoteLabel = '원문(책에 적힌 문장 또는 원문 참조)';
      expect(find.text(quoteLabel), findsNothing, reason: '원문은 접어 둔다');
      await tester.tap(find.byKey(const ValueKey('statement-source-toggle')));
      await tester.pumpAndSettle();
      expect(find.text(quoteLabel), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(mem.writes, 0, reason: '보기만 해서는 저장하지 않는다');
    });

    testWidgets('서술 더하기: 저장하면 확정 전 초안, 확정은 따로 누른다', (tester) async {
      final mem = _MemStatements();
      final c = _controller(mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);
      expect(find.text('서술 1'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('statement-add')));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('statement-confirm'));
      expect(tester.widget<ElevatedButton>(confirm).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('statement-field-title')), '경우의 수로 본 확률');
      await tester.enterText(find.byKey(const ValueKey('statement-field-body')), '경우의 수 비율');
      await tester.tap(find.byKey(const ValueKey('statement-save')));
      await tester.pumpAndSettle();
      expect(mem.rows.values.single.confirmed, isFalse);
      expect(find.textContaining('초안을 저장했습니다'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(confirm).onPressed, isNotNull);

      await tester.tap(confirm);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('statement-confirm-note')), '중등 표현');
      await tester.tap(find.byKey(const ValueKey('statement-confirm-ok')));
      await tester.pumpAndSettle();

      final row = mem.rows.values.single;
      expect(row.version, 1);
      expect(mem.revs[row.id]!.single.note, '중등 표현');
      expect(find.text('서술 2'), findsOneWidget);
      expect(find.text('서술 2/2 · 경우의 수로 본 확률'), findsOneWidget, reason: '만든 서술을 고른 채로 돌아온다');
      expect(tester.takeException(), isNull);
    });

    testWidgets('등장 위치: 교육과정 판을 모르면 미기록으로 남는다', (tester) async {
      final mem = _MemStatements();
      final c = _controller(mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);

      await tester.tap(find.byKey(const ValueKey('appearance-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('appearance-save')));
      await tester.pumpAndSettle();
      expect(find.text('학교급(초·중·고)을 고르세요.'), findsOneWidget);
      expect(mem.writes, 0);

      await tester.tap(find.byKey(const ValueKey('appearance-level-중')));
      await tester.enterText(find.byKey(const ValueKey('appearance-course')), '2-2');
      await tester.tap(find.byKey(const ValueKey('appearance-save')));
      await tester.pumpAndSettle();

      expect(mem.appearances.single.curriculumCode, isNull);
      expect(mem.appearances.single.statementId, isNull);
      expect(find.text('교육과정 판 미기록 · 중 2-2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('출처 창에서 출처를 다른 서술로 옮기면 그 서술의 출처 수가 바뀐다', (tester) async {
      final mem = _MemStatements();
      mem.rows['st-x'] = const ConceptStatement(
        id: 'st-x',
        conceptId: _concept,
        role: ConceptStatementRole.statement,
        version: 1,
        content: ConceptStatementText(title: '표본공간으로 본 확률', body: 'b'),
      );
      final lib = _Lib()..sources.addAll([_source(_src1, 10), _source(_src2, 11)]);
      final c = _controller(mem, lib: lib);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);
      expect(find.text('이 서술의 출처 2개'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('statement-sources')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-statement-$_src2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('표본공간으로 본 확률').last);
      await tester.pumpAndSettle();
      expect(mem.sourceOf[_src2], 'st-x');
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();

      expect(find.text('이 서술의 출처 1개'), findsOneWidget, reason: '기본 서술에는 1개만 남는다');
      await tester.tap(find.byKey(const ValueKey('statement-pick-st-x')));
      await tester.pumpAndSettle();
      expect(find.text('이 서술의 출처 1개'), findsOneWidget);
      expect(lib.sources.length, 2, reason: '출처 자체는 그대로');
    });
  });

  group('트리 칩', () {
    testWidgets('서술이 둘 이상이면 이름 뒤에 수를 붙인다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              ConceptTypeChip(name: '확률', style: conceptTypeStyle('정의'), statements: 3),
              ConceptTypeChip(name: '조건부확률', style: conceptTypeStyle('정의')),
            ],
          ),
        ),
      ));
      expect(find.byType(ConceptStatementCountMark), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });
  });
}
