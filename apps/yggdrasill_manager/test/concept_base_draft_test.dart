import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_library_pane.dart';
import 'package:yggdrasill_manager/services/concept_library_controller.dart';
import 'package:yggdrasill_manager/services/concept_library_service.dart';
import 'package:yggdrasill_manager/services/concept_service.dart';
import 'package:yggdrasill_manager/services/concept_statement_service.dart';
import 'package:yggdrasill_manager/services/concept_statement_store.dart';
import 'package:yggdrasill_manager/services/think/think_concept_chat_controller.dart';
import 'package:yggdrasill_manager/services/think/think_send_lock.dart';

const _concept = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b';
const _base = '모든 경우의 수에 대한 사건 A가 일어나는 경우의 수의 비율';
const _proposal = '각 경우가 일어날 가능성이 같을 때, 모든 경우의 수에 대한 사건 A가 일어나는 경우의 수의 비율';

ConceptItem _item([String content = _base]) =>
    ConceptItem(id: _concept, kind: ConceptKind.definition, name: '확률', content: content);

/// RPC와 같은 규칙(본 본문·저장 시각이 다르면 막음, 본문과 같으면 수정안 지움, 이유 없이 확정 안 함)을 흉내 낸다.
class _Mem implements ConceptStatementBackend {
  _Mem(this.content);

  String content;
  ConceptContentDraft? draft;
  final List<ConceptContentRevision> revs = [];
  bool tableMissing = false;
  int writes = 0;
  int _tick = 0;

  void _checkSaved(String? savedAt) {
    if (draft?.savedAtRaw != savedAt) throw ConceptStatementException('concept_content_draft_stale', '수정안이 바뀜');
  }

  @override
  Future<List<ConceptStatement>> statementsFor(String conceptId) async => const [];

  @override
  Future<Map<String, String?>> sourceStatements(String conceptId) async => const {};

  @override
  Future<List<ConceptAppearance>> appearancesFor(String conceptId) async => const [];

  @override
  Future<List<ConceptContentRevision>> contentRevisions(String conceptId) async => List.of(revs);

  @override
  Future<ConceptContentDraft?> contentDraft(String conceptId) async {
    if (tableMissing) throw ConceptStatementException('not_ready', '표 없음');
    return draft;
  }

  @override
  Future<ConceptContentDraft?> saveContentDraft({
    required String conceptId,
    required String content,
    String? note,
    required String base,
    ConceptContentDraft? current,
  }) async {
    writes += 1;
    if (conceptContentMd5(base) != conceptContentMd5(this.content)) {
      throw ConceptStatementException('concept_content_stale', '본문이 바뀜');
    }
    _checkSaved(current?.savedAtRaw);
    if (content == this.content) return draft = null;
    return draft = ConceptContentDraft(
      conceptId: conceptId,
      content: content,
      baseMd5: conceptContentMd5(base),
      note: note,
      savedAtRaw: 't${++_tick}',
    );
  }

  @override
  Future<String> confirmContentDraft(ConceptContentDraft d, {required String note}) async {
    writes += 1;
    _checkSaved(d.savedAtRaw);
    if (!draft!.basedOn(content)) throw ConceptStatementException('concept_content_base_changed', '바탕이 바뀜');
    if (note.trim().isEmpty) throw ConceptStatementException('concept_content_note_required', '이유 필요');
    revs.insert(
        0, ConceptContentRevision(name: '확률', content: content, viaDraft: true, note: note, draftOrigin: 'owner'));
    content = draft!.content;
    draft = null;
    return content;
  }

  @override
  Future<void> discardContentDraft(ConceptContentDraft d) async {
    writes += 1;
    _checkSaved(d.savedAtRaw);
    draft = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _Lib implements ConceptLibraryBackend {
  @override
  Future<List<ConceptSourceRef>> sourcesFor(String conceptId) async => const [];

  @override
  Future<List<String>> criterionIdsForConcept(String conceptId) async => const [];

  @override
  Future<String?> conceptTypeName(String conceptId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

ConceptLibraryController _controller(_Mem mem) =>
    ConceptLibraryController.forTest(_Lib(), chat: ConceptChatController.forTest(), statementBackend: mem);

Future<void> _pumpDetail(WidgetTester tester, ConceptLibraryController c,
    {Future<void> Function(String)? onBaseChanged}) async {
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
          child: ConceptDetailView(
            controller: c,
            onEdit: (_) {},
            onPickForChat: (_) {},
            onBaseChanged: onBaseChanged,
          ),
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

  group('기본 서술 수정안 저장소', () {
    test('수정안을 저장해도 본문은 그대로이고, 본문과 같은 글이면 수정안을 지운다', () async {
      final mem = _Mem(_base);
      final store = ConceptStatementStore(() => mem);
      await store.load(_concept);
      expect(store.contentDraftLoaded(_concept), isTrue);
      expect(store.contentDraftOf(_concept), isNull);

      final (d, err) = await store.saveContentDraft(_concept, content: _proposal, note: '조건 보완', base: _base);
      expect(err, isNull);
      expect(d!.basedOn(_base), isTrue);
      expect(mem.content, _base, reason: '확정 전에는 본문이 바뀌지 않는다');

      final (back, err2) = await store.saveContentDraft(_concept, content: _base, base: _base);
      expect(err2, isNull);
      expect(back, isNull);
      expect(store.contentDraftOf(_concept), isNull);
    });

    test('본 본문이 그사이 바뀌었으면 저장을 막고 오류 코드를 남긴다', () async {
      final mem = _Mem(_base);
      final store = ConceptStatementStore(() => mem);
      await store.load(_concept);
      mem.content = '다른 창에서 고친 본문';
      final (d, err) = await store.saveContentDraft(_concept, content: _proposal, base: _base);
      expect(d, isNull);
      expect(err, contains('본문이 바뀜'));
      expect(store.lastErrorCode, 'concept_content_stale');
    });

    test('수정안 저장소가 아직 없어도 서술은 읽고, 수정안 칸에만 이유를 보인다', () async {
      final mem = _Mem(_base)..tableMissing = true;
      final store = ConceptStatementStore(() => mem);
      await store.load(_concept);
      expect(store.loaded(_concept), isTrue);
      expect(store.errorOf(_concept), isNull);
      expect(store.contentDraftLoaded(_concept), isFalse);
      expect(store.contentDraftErrorOf(_concept), contains('마이그레이션'));
    });
  });

  group('개념 상세 기본 서술 수정안', () {
    testWidgets('수정안을 저장하고 이유를 적어 확정하면 본문이 바뀌고 기록에 이유가 남는다', (tester) async {
      final mem = _Mem(_base);
      final c = _controller(mem);
      c.selectConcept(_item());
      final changed = <String>[];
      await _pumpDetail(tester, c, onBaseChanged: (id) async => changed.add(id));
      expect(find.byKey(const ValueKey('base-draft-box')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('base-draft-open')));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('base-draft-save'));
      final confirm = find.byKey(const ValueKey('base-draft-confirm'));
      expect(tester.widget<OutlinedButton>(save).onPressed, isNull, reason: '본문 그대로면 저장할 것이 없다');
      expect(tester.widget<ElevatedButton>(confirm).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('base-draft-field')), _proposal);
      await tester.pump();
      expect(tester.widget<ElevatedButton>(confirm).onPressed, isNull, reason: '저장 전에는 확정하지 않는다');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(mem.draft!.content, _proposal);
      expect(mem.content, _base);
      expect(find.textContaining('수정안을 저장했습니다'), findsOneWidget);

      await tester.tap(confirm);
      await tester.pumpAndSettle();
      final ok = find.byKey(const ValueKey('base-draft-reason-ok'));
      expect(tester.widget<ElevatedButton>(ok).onPressed, isNull, reason: '이유 없이는 확정하지 않는다');
      await tester.enterText(find.byKey(const ValueKey('base-draft-reason')), '다른 교재에 조건이 적혀 있어 보완');
      await tester.pump();
      await tester.tap(ok);
      await tester.pumpAndSettle();

      expect(mem.content, _proposal);
      expect(mem.draft, isNull);
      expect(mem.revs.single.content, _base);
      expect(mem.revs.single.note, '다른 교재에 조건이 적혀 있어 보완');
      expect(c.selectedConcept!.content, _proposal, reason: '열어 둔 개념도 새 본문을 보인다');
      expect(changed, [_concept], reason: '트리를 다시 읽게 알린다');
      expect(find.byKey(const ValueKey('base-draft-box')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('수정안을 쓴 뒤 본문이 바뀌었으면 알리고, 다시 저장하기 전에는 확정하지 않는다', (tester) async {
      final mem = _Mem('바뀐 본문')
        ..draft = ConceptContentDraft(
          conceptId: _concept,
          content: _proposal,
          baseMd5: conceptContentMd5(_base),
          note: '조건 보완',
          savedAtRaw: 't0',
        );
      final c = _controller(mem);
      c.selectConcept(_item('바뀐 본문'));
      await _pumpDetail(tester, c);
      expect(find.byKey(const ValueKey('base-draft-box')), findsOneWidget);
      expect(find.byKey(const ValueKey('base-draft-moved')), findsOneWidget);
      expect(find.text('수정안 있음'), findsOneWidget, reason: '머리 배지');

      await tester.tap(find.byKey(const ValueKey('base-draft-open')));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('base-draft-confirm'));
      final save = find.byKey(const ValueKey('base-draft-save'));
      expect(tester.widget<ElevatedButton>(confirm).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(save).onPressed, isNotNull, reason: '지금 본문 기준으로 다시 저장할 수 있다');

      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(mem.draft!.basedOn('바뀐 본문'), isTrue);
      expect(tester.widget<ElevatedButton>(confirm).onPressed, isNotNull);
      expect(mem.content, '바뀐 본문', reason: '다시 저장해도 본문은 그대로');
      expect(tester.takeException(), isNull);
    });

    testWidgets('수정안을 버리면 본문은 그대로다', (tester) async {
      final mem = _Mem(_base)
        ..draft = ConceptContentDraft(
          conceptId: _concept,
          content: _proposal,
          baseMd5: conceptContentMd5(_base),
          savedAtRaw: 't0',
        );
      final c = _controller(mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);
      await tester.tap(find.byKey(const ValueKey('base-draft-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('base-draft-discard')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('버리기').last);
      await tester.pumpAndSettle();
      expect(mem.draft, isNull);
      expect(mem.content, _base);
      expect(find.text('수정안을 버렸습니다.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
