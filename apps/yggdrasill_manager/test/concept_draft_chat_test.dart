import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_draft_review_dialog.dart';
import 'package:yggdrasill_manager/screens/think/think_action_cards.dart';
import 'package:yggdrasill_manager/services/concept_book_service.dart';
import 'package:yggdrasill_manager/services/concept_draft_models.dart';
import 'package:yggdrasill_manager/services/concept_draft_service.dart';
import 'package:yggdrasill_manager/services/textbook_pdf_service.dart';
import 'package:yggdrasill_manager/services/think/think_action_models.dart';
import 'package:yggdrasill_manager/services/think/think_api.dart';
import 'package:yggdrasill_manager/services/think/think_concept_chat_controller.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';
import 'package:yggdrasill_manager/services/think/think_send_lock.dart';

const _draft = 'd0000000-0000-4000-8000-0000000000d1';
const _otherDraft = 'd0000000-0000-4000-8000-0000000000d2';
const _conv = '0d6c1b52-8a3e-4f5d-9b7c-1e2f3a4b5c6d';
const _userA = 'a0000000-0000-4000-8000-00000000000a';

final _noHttp = MockClient((_) async => http.Response('', 404));

ThinkStatus _status({bool draft = true}) => ThinkStatus.fromJson({
      'configured': true,
      'provider': 'openai',
      'capabilities': {if (draft) 'concept_draft_reference': 1},
    });

Map<String, dynamic> _row({Map<String, dynamic>? review, String? savedAt, String status = 'open', String? replacedBy}) => {
      'id': _draft,
      'academy_id': 'a1',
      'book_id': 'b1',
      'grade_label': '1-1',
      'book_name': '개념+유형 중1-1',
      'unit_path': ['소인수분해', '소수와 합성수'],
      'pages': [8, 9],
      'page_meta': [
        {'raw_page': 8, 'display_page': 8},
        {'raw_page': 9, 'display_page': 9},
      ],
      'status': status,
      'replaced_by': replacedBy,
      'model': 'gpt',
      'prepared': {
        'blocks': [
          {'id': 'p8-a0', 'raw_page': 8, 'read': 'a', 'kind': 'concept_box', 'title': '', 'text': '소수: 1보다 큰…'},
          {'id': 'p9-a1', 'raw_page': 9, 'read': 'a', 'kind': 'note', 'title': '참고', 'text': '합성수는…'},
        ],
        'disagreements': [],
      },
      'draft': {
        'summary': '개념 1개',
        'concepts': [
          {'title': '소수와 합성수', 'concept_type': '정의', 'content': '둘을 함께', 'source_blocks': ['p8-a0', 'p9-a1']},
        ],
        'new_types': [],
        'excluded': [],
        'questions': [],
      },
      'checks': {'unknown_ids': [], 'unaccounted': [], 'formula_warnings': [], 'concepts_without_source': []},
      'criteria': [],
      'folder_plan': null,
      'review': review ?? {},
      'review_saved_at': savedAt,
      'created_at': '2026-10-17T01:00:00Z',
    };

/// 저장된 검토: 하나를 둘로 나눈 상태(Think 제안 승인 뒤와 같은 모양).
Map<String, dynamic> _splitReview() => {
      'concepts': [
        {'key': 'c0.1', 'index': 0, 'mark': 'edit', 'title': '소수', 'content': '1보다 큰…', 'type': '정의', 'folder': ['대수', '수'], 'blocks': ['p8-a0']},
        {'key': 'c0.2', 'index': 0, 'mark': 'edit', 'title': '합성수', 'content': '약수가 셋 이상', 'type': '판정', 'folder': ['대수', '수'], 'blocks': ['p9-a1']},
      ],
      'new_types': [
        {'name': '판정', 'description': '가리는 기준', 'legacy_sub_type': '연산', 'closest_existing': '정의', 'reason': '절차', 'accept': null, 'origin': 'think'},
      ],
    };

class _FakeDraftService extends ConceptDraftService {
  _FakeDraftService(this.row)
      : super(books: ConceptBookService(pdf: TextbookPdfService(httpClient: _noHttp), httpClient: _noHttp));

  Map<String, dynamic> row;
  final List<List<ReviewItem>> saved = [];

  @override
  Future<ConceptDraftRecord> fetchDraft(String id) async => ConceptDraftRecord.fromRow(row);

  @override
  Future<List<List<String>>> libraryFolderPaths() async => const [
        ['대수'],
        ['대수', '수'],
      ];

  @override
  Future<List<ConceptTypeInfo>> conceptTypes() async =>
      const [ConceptTypeInfo(name: '정의', description: '뜻', legacySubType: '정의')];

  @override
  Future<String> saveReview(String id, List<ReviewItem> items, String? expectedSavedAt,
      {List<ReviewNewType> newTypes = const []}) async {
    saved.add(items);
    const at = '2026-10-17T02:00:00.000000+00:00';
    row = {
      ...row,
      'review': {
        'concepts': [for (final it in items) it.toJson()],
        'new_types': [for (final t in newTypes) t.toJson()],
      },
      'review_saved_at': at,
    };
    return at;
  }
}

ThinkAction _action(String kind, {String draftId = _draft, Map<String, dynamic>? payload, Map<String, dynamic>? preview}) =>
    ThinkAction.fromRow({
      'id': 'act-$kind',
      'conversation_id': _conv,
      'message_id': null,
      'kind': kind,
      'status': 'proposed',
      'payload': {'draft_id': draftId, ...?payload},
      'preview': preview ?? {},
      'result': null,
      'superseded': false,
      'created_at': '2026-10-17T01:00:00Z',
    })!;

VoidCallback? _onPressed(WidgetTester tester, String label) => tester
    .widget<ButtonStyleButton>(
        find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)))
    .onPressed;

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 760, height: 900, child: SingleChildScrollView(child: child)),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThinkSendLock.instance.resetForTest();
  });

  group('검토 항목 key·근거 블록', () {
    test('key는 없으면 c{번호}이고, 나눈 항목은 key·blocks를 그대로 저장한다', () {
      const plain = ReviewItem(index: 2, mark: ReviewMark.keep, title: 't', content: 'c', type: '정의', folder: []);
      expect(plain.key, 'c2');
      expect(plain.isOriginal, isTrue);
      expect(plain.toJson().containsKey('blocks'), isFalse);

      final split = ReviewItem.fromJson(_splitReview()['concepts'][1] as Map<String, dynamic>);
      expect(split.key, 'c0.2');
      expect(split.isOriginal, isFalse);
      expect(split.blocks, ['p9-a1']);
      expect(split.toJson()['key'], 'c0.2');
      expect(split.toJson()['blocks'], ['p9-a1']);
    });

    test('저장된 순서를 지키고, 근거·출처 쪽은 항목의 blocks에서 고른다', () {
      final r = ConceptDraftRecord.fromRow(_row(review: _splitReview(), savedAt: '2026-10-17T02:00:00Z'));
      final items = initialReview(r);
      expect([for (final it in items) it.key], ['c0.1', 'c0.2']);
      expect([for (final b in r.blocksForItem(items[1])) b.id], ['p9-a1']);
      expect(r.sourcePagesFor(items[0]), [8]);
      expect(r.sourcePagesFor(items[1]), [9]);
      expect(r.sourcePages(0), [8, 9], reason: 'AI 결과의 근거는 그대로');
      expect(sameReview(items, r.review, initialNewTypes(r), r.reviewNewTypes), isTrue);

      final types = initialNewTypes(r);
      expect([for (final t in types) t.name], ['판정'], reason: 'Think가 더한 새 유형도 검토 창에 보인다');
      expect(types.single.fromThink, isTrue);
    });

    test('근거 블록만 달라도 같은 검토가 아니다', () {
      final r = ConceptDraftRecord.fromRow(_row(review: _splitReview(), savedAt: '2026-10-17T02:00:00Z'));
      final items = initialReview(r);
      final moved = [
        items[0],
        ReviewItem.fromJson({...items[1].toJson(), 'blocks': ['p8-a0']}),
      ];
      expect(sameReview(moved, items), isFalse);
    });

    test('다시 정리한 초안은 "다시 정리함"으로 보인다', () {
      expect(conceptDraftStatusLabel('replaced'), '다시 정리함');
      final r = ConceptDraftRecord.fromRow(_row(status: 'replaced', replacedBy: _otherDraft));
      expect(r.isOpen, isFalse);
      expect(r.replacedBy, _otherDraft);
    });
  });

  group('검토 대화 요청·컨트롤러', () {
    test('초안은 id만 보낸다(검토 본문·미저장 편집은 보내지 않는다)', () {
      final body = ThinkApi.chatRequestBody(
        conversationId: null,
        draftId: _draft,
        message: '3번과 4번은 같은 개념 아니야?',
        attachments: const [],
        deep: false,
        webSearch: false,
      );
      expect(body['draft_id'], _draft);
      expect(body['conversation_id'], isNull);
      expect(jsonEncode(body).contains('소수와 합성수'), isFalse);
      final plain = ThinkApi.chatRequestBody(
        conversationId: _conv,
        message: 'x',
        attachments: const [],
        deep: false,
        webSearch: false,
      );
      expect(plain.containsKey('draft_id'), isFalse);
    });

    test('서버가 알려 준 초안 읽기 결과를 읽는다', () {
      expect(DraftReadInfo.parse(null).status, 'unsupported');
      expect(DraftReadInfo.parse({'draft': null}).status, 'skipped');
      final r = DraftReadInfo.parse({
        'draft': {'status': 'truncated', 'draft_status': 'open', 'review_saved_at': '2026-10-17T02:00:00Z', 'items': 2, 'blocks_cut': true},
      });
      expect(r.status, 'truncated');
      expect(r.items, 2);
      expect(r.blocksCut, isTrue);
      expect(r.reviewSavedAt, isNotNull);
    });

    test('대화가 없어도 열린 초안이면 보낼 수 있고, 닫힌 초안·옛 서버는 막는다', () {
      final c = ConceptChatController.forTest(draftMode: true)..status = _status();
      expect(c.blockedReason, contains('초안을 연 뒤'));
      c.setDraft(_draft);
      expect(c.blockedReason, isNull, reason: '첫 질문에서 새 검토 대화를 만든다');
      c.setDraft(_draft, open: false);
      expect(c.blockedReason, contains('닫힌 초안'));
      c
        ..setDraft(_draft)
        ..status = _status(draft: false);
      expect(c.blockedReason, contains('배포'));

      final concept = ConceptChatController.forTest()..status = _status();
      expect(concept.blockedReason, isNotNull, reason: '개념 탭 대화는 여전히 기존 대화를 골라야 한다');
    });

    test('검토 대화는 개념 탭과 다른 곳에 저장하고, 새 대화로 바꾸면 지운다', () async {
      SharedPreferences.setMockInitialValues({
        ConceptChatController.draftPrefsKey(_userA): jsonEncode({'conversation_id': _conv}),
      });
      final c = ConceptChatController.forTest(draftMode: true);
      await c.switchAccountForTest(_userA);
      expect(c.conversationId, _conv);
      final tab = ConceptChatController.forTest();
      await tab.switchAccountForTest(_userA);
      expect(tab.conversationId, isNull);

      await c.startNewConversation();
      expect(c.conversationId, isNull);
      expect(c.link, ConceptChatLink.none);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ConceptChatController.draftPrefsKey(_userA)), isNull);
    });
  });

  group('초안 제안 카드', () {
    final change = _action(
      'concept_draft_change',
      payload: {
        'ops': [
          {'op': 'split', 'key': 'c0', 'parts': [{}, {}]},
          {'op': 'new_type', 'name': '판정'},
        ],
        'reason': '둘은 다른 개념',
      },
      preview: {
        'title': '개념 초안 변경 2건',
        'draft_label': '개념+유형 중1-1 · 소수와 합성수',
        'before': {
          'c0': {'key': 'c0', 'index': 0, 'mark': 'keep', 'title': '소수와 합성수', 'content': '둘을 함께', 'type': '정의', 'folder': []},
        },
        'after': [
          {'key': 'c0.1', 'index': 0, 'mark': 'edit', 'title': '소수', 'content': '1보다 큰…', 'type': '정의', 'folder': []},
          {'key': 'c0.2', 'index': 0, 'mark': 'edit', 'title': '합성수', 'content': '약수가 셋 이상', 'type': '판정', 'folder': []},
        ],
        'new_types': [
          {'name': '판정', 'description': '가리는 기준'},
        ],
        'reason': '둘은 다른 개념',
      },
    );

    testWidgets('변경 내용과 바뀐 항목을 보이고, 검토 창의 승인으로 넘긴다', (tester) async {
      final approved = <String>[];
      await tester.pumpWidget(_host(ConceptDraftCardScope(
        draftId: _draft,
        draftOpen: true,
        approve: (a) async => approved.add(a.id),
        rerun: (a) async {},
        child: ThinkActionCard(action: change),
      )));
      expect(find.text('개념 초안 변경 제안'), findsOneWidget);
      expect(find.text('· c0 2개로 나누기'), findsOneWidget);
      expect(find.text('· 새 종류 "판정"'), findsOneWidget);
      expect(find.text('c0.1'), findsOneWidget);
      expect(find.text('목록에서 빠짐'), findsOneWidget, reason: '나눈 원래 항목');
      await tester.ensureVisible(find.text('승인'));
      await tester.tap(find.text('승인'));
      await tester.pump();
      expect(approved, ['act-concept_draft_change']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('다른 초안의 카드와 검토 창 밖의 다시 정리는 승인할 수 없다', (tester) async {
      await tester.pumpWidget(_host(ConceptDraftCardScope(
        draftId: _otherDraft,
        draftOpen: true,
        approve: (a) async => fail('다른 초안은 승인하지 않는다'),
        rerun: (a) async {},
        child: ThinkActionCard(action: change),
      )));
      expect(find.textContaining('다른 초안에 대한 카드'), findsOneWidget);
      expect(_onPressed(tester, '승인'), isNull);

      final rerun = _action('concept_draft_rerun', preview: {
        'title': '같은 쪽 다시 정리',
        'criteria': [
          {'id': 'k1', 'title': '지식 분류', 'version': 2, 'has_draft': true},
        ],
      });
      await tester.pumpWidget(_host(ThinkActionCard(key: const ValueKey('r'), action: rerun)));
      expect(find.textContaining('검토 창에서 승인'), findsOneWidget);
      expect(find.textContaining('지식 분류 (확정 v2 + 저장된 초안)'), findsOneWidget);
      expect(_onPressed(tester, '승인하고 다시 정리'), isNull);
    });

    testWidgets('기준 고치기 카드는 지금 기준과 바꿀 내용을 나란히 보인다', (tester) async {
      final crit = _action('concept_criterion_change', preview: {
        'title': '정리 기준 고치기: 지식 분류',
        'before': {'title': '지식 분류', 'body': '예전 기준', 'state': 'confirmed', 'version': 2},
        'after': {'title': '지식 분류', 'body': '새 기준'},
      });
      await tester.pumpWidget(_host(ThinkActionCard(action: crit)));
      expect(find.text('지금(확정 v2)'), findsOneWidget);
      expect(find.text('새 기준'), findsOneWidget);
      expect(find.textContaining('초안으로만 저장'), findsOneWidget);
    });
  });

  group('검토 창 대화', () {
    Future<void> pumpDialog(WidgetTester tester, _FakeDraftService svc, ConceptChatController chat) async {
      tester.view.physicalSize = const Size(1600, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showConceptDraftReviewDialog(context, draftId: _draft, service: svc, chat: chat),
              child: const Text('열기'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
    }

    testWidgets('넓은 화면에서 옆에 대화를 열고, 나눈 항목은 key로 보인다', (tester) async {
      final svc = _FakeDraftService(_row(review: _splitReview(), savedAt: '2026-10-17T02:00:00Z'));
      final chat = ConceptChatController.forTest(draftMode: true)..status = _status();
      await pumpDialog(tester, svc, chat);
      expect(find.text('Think와 초안 검토'), findsOneWidget);
      expect(chat.draftId, _draft, reason: '열린 초안을 대화에 알린다');
      expect(find.text('c0.1'), findsOneWidget);
      expect(find.text('c0.2'), findsOneWidget);
      expect(find.textContaining('출처: PDF 9쪽'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('draft-chat-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Think와 초안 검토'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('보내기 전에 저장하지 않은 검토를 먼저 저장한다', (tester) async {
      final svc = _FakeDraftService(_row());
      final chat = ConceptChatController.forTest(draftMode: true)..status = _status();
      await pumpDialog(tester, svc, chat);
      chat.composer.text = '이 개념을 둘로 나눠야 할까?';
      await tester.pump();
      // 보내기는 실제 서버를 부르므로, 저장까지만 확인하고 요청은 실패로 끝난다.
      expect(_onPressed(tester, '보내기'), isNotNull);
      await tester.tap(find.text('보내기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(svc.saved, hasLength(1), reason: '한 번도 저장하지 않은 검토를 먼저 저장한다');
      await tester.pumpAndSettle();
    });

    testWidgets('다시 정리해 닫힌 초안은 새 초안 열기를 보인다', (tester) async {
      final svc = _FakeDraftService(_row(status: 'replaced', replacedBy: _otherDraft));
      final chat = ConceptChatController.forTest(draftMode: true)..status = _status();
      await pumpDialog(tester, svc, chat);
      expect(find.text('다시 정리함'), findsOneWidget);
      expect(find.text('새 초안 열기'), findsOneWidget);
      expect(chat.draftOpen, isFalse);
      expect(chat.blockedReason, contains('닫힌 초안'));
    });
  });
}
