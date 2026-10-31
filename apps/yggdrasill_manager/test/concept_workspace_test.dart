import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_book_dialog.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_criteria_pane.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_library_pane.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_workspace.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/course_map_pane.dart';
import 'package:yggdrasill_manager/services/concept_book_order.dart';
import 'package:yggdrasill_manager/services/concept_book_service.dart';
import 'package:yggdrasill_manager/services/concept_draft_models.dart';
import 'package:yggdrasill_manager/services/concept_draft_service.dart';
import 'package:yggdrasill_manager/services/concept_library_controller.dart';
import 'package:yggdrasill_manager/services/concept_library_service.dart';
import 'package:yggdrasill_manager/services/concept_service.dart';
import 'package:yggdrasill_manager/services/course_map_controller.dart';
import 'package:yggdrasill_manager/services/textbook_pdf_service.dart';
import 'package:yggdrasill_manager/services/think/think_api.dart';
import 'package:yggdrasill_manager/services/think/think_concept_chat_controller.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';
import 'package:yggdrasill_manager/services/think/think_send_lock.dart';

import 'course_map_fake.dart';

const _conv = '0d6c1b52-8a3e-4f5d-9b7c-1e2f3a4b5c6d';
const _conceptA = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b';
const _crit = '3c2b1a00-9e8d-4c7b-8a69-5f4e3d2c1b0a';
const _academy = 'ac000000-0000-4000-8000-0000000000ac';
const _book = 'b0000000-0000-4000-8000-0000000000bb';
const _book2 = 'b0000000-0000-4000-8000-0000000000b2';
const _book3 = 'b0000000-0000-4000-8000-0000000000b3';
const _userA = 'a0000000-0000-4000-8000-00000000000a';
const _userB = 'b0000000-0000-4000-8000-00000000000b';

ConceptItem _concept(String id, {String name = '소인수분해'}) =>
    ConceptItem(id: id, kind: ConceptKind.definition, name: name, content: '자연수를 소수의 곱으로 나타내는 것');

ThinkStatus _status({bool criterionReference = false}) => ThinkStatus.fromJson({
      'configured': true,
      'provider': 'openai',
      'capabilities': {'concept_reference': 2, if (criterionReference) 'criterion_reference': 1},
    });

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// RPC와 같은 규칙(판·초안 저장 시각이 다르면 막음, 확정본과 같으면 초안 비움)을 메모리로 흉내 낸다.
class _FakeBackend implements ConceptLibraryBackend {
  final Map<String, Map<String, dynamic>> rows = {};
  final Map<String, List<ConceptCriterionRevision>> revisions = {};
  final Map<String, Set<String>> links = {};
  final Map<String, String> conceptNames = {};
  final Map<String, List<ConceptSourceRef>> sources = {};
  int writes = 0;
  int _seq = 0;
  int _tick = 0;

  String _id() => '00000000-0000-4000-8000-${(++_seq).toString().padLeft(12, '0')}';
  String _now() => DateTime.utc(2026, 10, 16, 12).add(Duration(microseconds: 1001 * ++_tick)).toIso8601String();

  String seed({String? title, String? body, int version = 0, String? draftTitle, String? draftBody, String? origin}) {
    final id = _id();
    rows[id] = {
      'id': id,
      'sort_order': _seq,
      'title': title,
      'body': body,
      'version': version,
      'confirmed_at': version > 0 ? _now() : null,
      'draft_title': draftTitle,
      'draft_body': draftBody,
      'draft_origin': draftTitle == null ? null : (origin ?? 'owner'),
      'draft_saved_at': draftTitle == null ? null : _now(),
    };
    return id;
  }

  /// 다른 곳에서 저장한 것처럼 초안 저장 시각만 바꾼다.
  void touch(String id) => rows[id]!['draft_saved_at'] = _now();

  ConceptCriterion _row(String id) => ConceptCriterion.fromRow(rows[id]!);

  Never _fail(String code) => throw ConceptLibraryException.from(PostgrestException(message: code, code: 'P0001'));

  Map<String, dynamic> _current(ConceptCriterion base) {
    final r = rows[base.id];
    if (r == null) _fail('concept_criteria_not_found');
    if (r['version'] != base.version || r['draft_saved_at']?.toString() != base.draftSavedAtRaw) {
      _fail('concept_criteria_stale');
    }
    return r;
  }

  @override
  Future<List<ConceptCriterion>> listCriteria() async => [for (final id in rows.keys) _row(id)];

  @override
  Future<ConceptCriterion> createCriterion(
      {required String title, required String body, String origin = 'owner'}) async {
    writes += 1;
    return _row(seed(draftTitle: title, draftBody: body, origin: origin));
  }

  @override
  Future<ConceptCriterion> saveDraft(ConceptCriterion base, {required String title, required String body}) async {
    final r = _current(base);
    writes += 1;
    if ((r['version'] as int) > 0 && r['title'] == title && r['body'] == body) {
      r
        ..['draft_title'] = null
        ..['draft_body'] = null
        ..['draft_origin'] = null
        ..['draft_saved_at'] = null;
    } else {
      r
        ..['draft_title'] = title
        ..['draft_body'] = body
        ..['draft_origin'] = 'owner'
        ..['draft_saved_at'] = _now();
    }
    return _row(base.id);
  }

  @override
  Future<ConceptCriterion> confirm(ConceptCriterion base, {String? note}) async {
    final r = _current(base);
    if (r['draft_title'] == null) _fail('concept_criteria_no_draft');
    writes += 1;
    final v = (r['version'] as int) + 1;
    r
      ..['title'] = r['draft_title']
      ..['body'] = r['draft_body']
      ..['version'] = v
      ..['confirmed_at'] = _now()
      ..['draft_title'] = null
      ..['draft_body'] = null
      ..['draft_origin'] = null
      ..['draft_saved_at'] = null;
    revisions.putIfAbsent(base.id, () => []).insert(
          0,
          ConceptCriterionRevision(version: v, title: r['title'] as String, body: r['body'] as String, note: note),
        );
    return _row(base.id);
  }

  @override
  Future<ConceptCriterion?> discardDraft(ConceptCriterion base) async {
    final r = _current(base);
    writes += 1;
    if (r['version'] == 0) {
      rows.remove(base.id);
      return null;
    }
    r
      ..['draft_title'] = null
      ..['draft_body'] = null
      ..['draft_origin'] = null
      ..['draft_saved_at'] = null;
    return _row(base.id);
  }

  @override
  Future<List<ConceptCriterionRevision>> listRevisions(String criterionId) async => revisions[criterionId] ?? const [];

  @override
  Future<List<String>> criterionIdsForConcept(String conceptId) async => [
        for (final e in links.entries)
          if (e.value.contains(conceptId)) e.key
      ];

  @override
  Future<List<ConceptLinkedConcept>> conceptsForCriterion(String criterionId) async => [
        for (final id in links[criterionId] ?? const <String>{})
          ConceptLinkedConcept(conceptId: id, name: conceptNames[id] ?? '', kind: ConceptKind.definition),
      ];

  @override
  Future<void> link({required String criterionId, required String conceptId}) async {
    writes += 1;
    links.putIfAbsent(criterionId, () => {}).add(conceptId);
  }

  @override
  Future<void> unlink({required String criterionId, required String conceptId}) async {
    writes += 1;
    links[criterionId]?.remove(conceptId);
  }

  @override
  Future<List<ConceptSourceRef>> sourcesFor(String conceptId) async => [...?sources[conceptId]];

  final Map<String, String> conceptTypes = {};

  @override
  Future<String?> conceptTypeName(String conceptId) async => conceptTypes[conceptId];

  @override
  Future<ConceptSourceRef> addSource({
    required String conceptId,
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int rawPage,
    int? displayPage,
    List<String> unitPath = const [],
  }) async {
    final list = sources.putIfAbsent(conceptId, () => []);
    if (list.any((s) => s.bookId == bookId && s.gradeLabel == gradeLabel && s.rawPage == rawPage)) {
      throw ConceptLibraryException('duplicate', '이 쪽은 이미 이 개념의 출처로 이어져 있습니다.');
    }
    writes += 1;
    final s = ConceptSourceRef(
      id: _id(),
      conceptId: conceptId,
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      rawPage: rawPage,
      displayPage: displayPage,
      unitPath: unitPath,
      bookName: '개념원리 공통수학1',
    );
    list.add(s);
    return s;
  }

  @override
  Future<void> removeSource(String id) async {
    writes += 1;
    for (final list in sources.values) {
      list.removeWhere((s) => s.id == id);
    }
  }
}

ConceptLibraryController _controller(_FakeBackend backend, {ConceptChatController? chat}) =>
    ConceptLibraryController.forTest(backend, chat: chat ?? ConceptChatController.forTest());

/// 예전 교재 탭 저장 형식: 시리즈 키 없이 smalls에 실제 소단원과 쪽 범위가 있다.
Map<String, dynamic> _legacyPayload() => {
      'units': [
        {
          'name': 'I. 수와 연산',
          'middles': [
            {
              'name': '1. 소인수분해',
              'smalls': [
                {'name': '소인수분해', 'start_page': 8, 'end_page': 13},
                {'name': '최대공약수와 최소공배수', 'start_page': 14, 'end_page': 20},
                {'name': '단원마무리', 'start_page': 21, 'end_page': 25},
              ],
            },
          ],
        },
      ],
    };

class _FakeBookService extends ConceptBookService {
  _FakeBookService(this.books, this.crops) : super(pdf: TextbookPdfService(httpClient: _noHttp), httpClient: _noHttp);

  static final _noHttp = MockClient((_) async => http.Response('', 404));

  final List<ConceptBookEntry> books;
  final Map<String, Map<int, ConceptBookCropPage>> crops;

  @override
  Future<List<ConceptBookEntry>> listBooks() async => books;

  @override
  Future<int> problemCount(ConceptBookEntry book) async =>
      (crops[book.key] ?? const {}).values.fold<int>(0, (sum, p) => sum + p.problems);

  @override
  Future<Map<int, ConceptBookCropPage>> problemPages(ConceptBookEntry book) async => crops[book.key] ?? const {};
}

class _FakeCoverageService extends ConceptDraftService {
  _FakeCoverageService(this.result) : super(books: _FakeBookService(const [], const {}));

  final ConceptDraftCoverage result;

  @override
  Future<ConceptDraftCoverage> coverage() async => result;
}

TextField _fieldOf(WidgetTester tester, TextEditingController controller) => tester.widget<TextField>(
      find.byWidgetPredicate((w) => w is TextField && w.controller == controller),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThinkSendLock.instance.resetForTest();
  });

  group('정리 기준 저장', () {
    test('새 기준은 초안으로만 저장되고, 확정은 따로 눌러야 한다. 다시 들어와도 그대로다', () async {
      final backend = _FakeBackend();
      final a = _controller(backend);
      await a.loadCriteria();
      final local = a.addCriterion();
      a.editOf(local).title.text = '노드 분리 기준';
      a.editOf(local).body.text = '정의 하나에 노드 하나';
      expect(a.isDirty(local), isTrue);

      expect(await a.saveDraft(local), isTrue);
      final saved = a.criteria.single;
      expect(saved.confirmed, isFalse);
      expect(saved.hasDraft, isTrue);
      expect(a.selectedCriterionId, saved.id);
      expect(a.isDirty(saved.id), isFalse);
      expect(a.editOf(saved.id).body.text, '정의 하나에 노드 하나', reason: '저장한 뒤에도 같은 입력 칸이 이어진다');

      final again = _controller(backend);
      await again.loadCriteria();
      expect(again.criteria.single.draftTitle, '노드 분리 기준');
      expect(again.criteria.single.version, 0);

      expect(await again.confirm(saved.id, note: '처음 확정'), isTrue);
      final row = again.criteria.single;
      expect(row.version, 1);
      expect(row.title, '노드 분리 기준');
      expect(row.hasDraft, isFalse);
      expect(backend.revisions[saved.id]!.single.note, '처음 확정');
    });

    test('저장 안 한 입력이 있으면 확정하지 않고, 그사이 바뀌었으면 입력을 남긴 채 막는다', () async {
      final backend = _FakeBackend();
      final id = backend.seed(title: '대표 용어', body: '교육과정 용어', version: 1, draftTitle: '대표 용어', draftBody: '교과서 용어');
      final c = _controller(backend);
      await c.loadCriteria();
      c.editOf(id).body.text = '교과서 용어를 먼저';
      expect(await c.confirm(id), isFalse);
      expect(backend.writes, 0);

      backend.touch(id);
      expect(await c.saveDraft(id), isFalse);
      expect(c.errors[id], contains('그사이 이 기준이 바뀌었습니다'));
      await _settle();
      expect(c.editOf(id).body.text, '교과서 용어를 먼저', reason: '최신 저장본을 다시 읽어도 입력은 그대로');
      expect(c.isDirty(id), isTrue);

      expect(await c.saveDraft(id), isTrue, reason: '다시 읽은 저장본을 기준으로 저장한다');
      expect(backend.rows[id]!['draft_body'], '교과서 용어를 먼저');
      expect(backend.rows[id]!['body'], '교육과정 용어', reason: '확정본은 그대로');
    });

    test('확정한 적 없는 항목의 초안을 버리면 항목이 지워지고 대화 참고에서도 빠진다', () async {
      final backend = _FakeBackend();
      final id = backend.seed(draftTitle: '관계 정의', draftBody: '먼저 알아야 하는 개념');
      final chat = ConceptChatController.forTest();
      final c = _controller(backend, chat: chat);
      await c.loadCriteria();
      expect(chat.pickCriterion(c.criterionById(id)!), isNull);

      expect(await c.discardDraft(id), isTrue);
      expect(c.criteria, isEmpty);
      expect(backend.rows, isEmpty);
      expect(chat.criterionId, isNull);
    });

    test('다른 곳에서 지운 기준을 고치던 중이면 글을 새 항목으로 남긴다', () async {
      final backend = _FakeBackend();
      final id = backend.seed(draftTitle: '예외', draftBody: '');
      final c = _controller(backend);
      await c.loadCriteria();
      c.editOf(id).body.text = '고치던 글';
      backend.rows.remove(id);

      await c.loadCriteria();
      expect(c.isLocal(id), isTrue);
      expect(c.editOf(id).body.text, '고치던 글');
      expect(c.errors[id], contains('다른 곳에서 지워졌습니다'));
    });

    test('기본 틀은 "기본 틀" 초안으로만 들어가고 확정되지 않는다', () async {
      final backend = _FakeBackend();
      final c = _controller(backend);
      await c.loadCriteria();
      expect(await c.createTemplates(), kConceptCriterionTemplates.length);
      expect(c.criteria.every((x) => x.templateDraft && !x.confirmed), isTrue);
      expect(c.criteria.first.draftBody, contains('아직 확정한 기준이 아닙니다'));
      expect(c.missingTemplates, isEmpty);
      expect(await c.createTemplates(), 0, reason: '같은 제목은 다시 만들지 않는다');
    });

    test('크게 보기·요약에서 열기는 저장·확정·연결을 하지 않는다', () async {
      final backend = _FakeBackend();
      final id = backend.seed(title: '지식 분류', body: '네 가지', version: 1);
      final c = _controller(backend);
      await c.loadCriteria();
      c.editOf(id).body.text = '네 가지 + 예외';

      c.setFocus(ConceptWorkspaceFocus.courseMap);
      c.openConcept(_concept(_conceptA));
      c.openCriterion(id);
      expect(c.focus, ConceptWorkspaceFocus.library, reason: '기준은 창으로 열고 칸은 바꾸지 않는다');
      expect(c.criteriaDialogRequest.value, 1);
      c.setFocus(ConceptWorkspaceFocus.courseMap);
      await _settle();

      expect(backend.writes, 0);
      expect(c.editOf(id).body.text, '네 가지 + 예외');
      expect(c.selectedConcept?.id, _conceptA);
      expect(c.selectedCriterionId, id);
    });
  });

  group('정리 기준 대화 참고', () {
    test('기준 id만 따로 보내고 기준 본문·저장 안 한 입력은 보내지 않는다', () {
      final body = ThinkApi.chatRequestBody(
        conversationId: _conv,
        criterionId: _crit,
        message: '이 기준으로 나누면 어떻게 돼?',
        attachments: const [],
        deep: false,
        webSearch: false,
      );
      expect(body['criterion_id'], _crit);
      expect(body.containsKey('concept_id'), isFalse);
      expect(jsonEncode(body), isNot(contains('정의 하나에 노드 하나')));

      final fresh = ThinkApi.chatRequestBody(
        conversationId: null,
        criterionId: _crit,
        message: 'hi',
        attachments: const [],
        deep: false,
        webSearch: false,
      );
      expect(fresh.containsKey('criterion_id'), isFalse, reason: '새 대화에는 붙이지 않는다');
    });

    test('저장 전 기준은 고를 수 없고, 서버가 기준 참고를 모르면 보내지 않는다', () {
      final chat = ConceptChatController.forTest()
        ..conversationId = _conv
        ..link = ConceptChatLink.ready
        ..status = _status();
      expect(chat.pickCriterion(const ConceptCriterion(id: 'new-1', draftTitle: '새 기준')), isNotNull);
      expect(chat.criterionId, isNull);

      expect(chat.pickCriterion(const ConceptCriterion(id: _crit, draftTitle: '새 기준')), isNull);
      expect(chat.blockedReason, contains('정리 기준 참고를 모르는 버전'));
      chat.status = _status(criterionReference: true);
      expect(chat.blockedReason, isNull);
      chat.status = _status();
      chat.clearCriterion();
      expect(chat.blockedReason, isNull, reason: '기준 없이 이야기하는 것은 막지 않는다');
    });

    test('계정마다 고른 기준 id만 저장하고, 계정을 바꾸면 비운다', () async {
      final chat = ConceptChatController.forTest();
      await chat.switchAccountForTest(_userA);
      expect(chat.pickCriterion(const ConceptCriterion(id: _crit, title: '지식 분류', version: 2)), isNull);
      await _settle();
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(ConceptChatController.prefsKey(_userA))!) as Map;
      expect(saved['criterion_id'], _crit);
      expect(jsonEncode(saved), isNot(contains('지식 분류')), reason: '제목·본문은 기기에 저장하지 않는다');

      await chat.switchAccountForTest(_userB);
      expect(chat.criterionId, isNull);
      await chat.switchAccountForTest(_userA);
      expect(chat.criterionId, _crit);
    });

    test('서버가 읽은 결과: 옛 서버·건너뜀·읽지 못한 연결을 구분한다', () {
      expect(CriterionReadInfo.parse(null).status, 'unsupported');
      expect(CriterionReadInfo.parse({'concept': null}).status, 'unsupported');
      expect(CriterionReadInfo.parse({'criterion': null}).status, 'skipped');
      final r = CriterionReadInfo.parse({
        'criterion': {
          'id': _crit,
          'status': 'ok',
          'version': 2,
          'confirmed_at': '2026-10-16T01:00:00.123456Z',
          'has_draft': true,
          'draft_saved_at': '2026-10-16T02:00:00Z',
          'linked_concepts': null,
        },
      });
      expect(r.status, 'ok');
      expect(r.version, 2);
      expect(r.hasDraft, isTrue);
      expect(r.linkedConcepts, isNull, reason: '읽지 못한 연결은 0개로 바꾸지 않는다');

      final concept = ConceptReadInfo.parse({
        'concept': {'id': _conceptA, 'status': 'ok', 'linked_criteria': 2, 'sources': null},
      });
      expect(concept.linksReported, isTrue);
      expect(concept.linkedCriteria, 2);
      expect(concept.sources, isNull);
      expect(
          ConceptReadInfo.parse({
            'concept': {'id': _conceptA, 'status': 'ok'}
          }).linksReported,
          isFalse);
    });
  });

  group('개념책 쪽 표시', () {
    test('문항 기록이 있는 소단원에서 문항 없는 쪽만 개념 페이지로 표시하고, 모르는 것은 채우지 않는다', () {
      final units = conceptBookUnitsFromPayload({
        'version': 2,
        'series': 'wonri',
        'units': [
          {
            'name': 'I. 다항식',
            'middles': [
              {
                'name': '1. 다항식의 연산',
                'smalls': [
                  {'sub_key': 'A', 'name': '개념원리 익히기', 'start_page': 8, 'end_page': 16},
                ],
                'sub_units': [
                  {'name': '다항식의 덧셈과 뺄셈', 'order_index': 0, 'start_page': 8, 'end_page': 11},
                  {'name': '다항식의 곱셈', 'order_index': 1, 'start_page': 12, 'end_page': 14},
                  {'name': '연습문제', 'order_index': 2, 'start_page': 15, 'end_page': 16, 'is_exercise': true},
                  {'name': '쪽 없음', 'order_index': 3},
                ],
              },
            ],
          },
        ],
      });
      expect(units.any((u) => u.slot), isFalse, reason: '실제 소단원 목록이 있으면 문항 묶음 칸은 쓰지 않는다');
      final crops = {
        10: const ConceptBookCropPage(problems: 3, displayPage: 8),
        11: const ConceptBookCropPage(problems: 2, displayPage: 9),
        15: const ConceptBookCropPage(problems: 6),
      };
      final pages = conceptBookUnitPages(units, crops);
      expect(pages, hasLength(4));

      final first = pages[0];
      expect(first.path, ['I. 다항식', '1. 다항식의 연산', '다항식의 덧셈과 뺄셈']);
      expect(first.extracted, isTrue);
      expect([
        for (final p in first.pages)
          if (first.isConceptPage(p)) p.rawPage
      ], [
        8,
        9
      ]);
      expect(first.pages[2].problems, 3);
      expect(first.pages[2].displayPage, 8);
      expect(first.pages[0].displayPage, isNull, reason: '문항 없는 쪽의 인쇄 쪽 번호는 추정하지 않는다');

      final second = pages[1];
      expect(second.extracted, isFalse);
      expect(second.pages.any(second.isConceptPage), isFalse, reason: '문항 기록이 없으면 추출 전일 수 있어 표시하지 않는다');

      expect(pages[2].isExercise, isTrue);
      expect([
        for (final p in pages[2].pages)
          if (pages[2].isConceptPage(p)) p.rawPage
      ], [
        16
      ]);
      expect(pages[3].hasRange, isFalse);
      expect(pages[3].pages, isEmpty);
    });

    test('예전 교재 탭에서 smalls에 저장한 소단원도 읽고, 개념서 시리즈로 등록된 교재는 개념서로 본다', () {
      final legacy = ConceptBookEntry.fromMetadataRow({
        'academy_id': _academy,
        'book_id': _book,
        'grade_label': '1-1',
        'textbook_type': '개념서',
        'payload': _legacyPayload(),
      }, bookName: '개념+유형');
      expect(legacy.isConceptBook, isTrue);
      expect(legacy.seriesKey, isNull);
      expect(legacy.subUnitCount, 3);
      expect(legacy.slotCount, 0);
      expect(legacy.units.first.path, ['I. 수와 연산', '1. 소인수분해', '소인수분해']);
      expect(legacy.units.last.isExercise, isFalse, reason: '저장되지 않은 연습문제 여부는 이름으로 짐작하지 않는다');
      final pages = conceptBookUnitPages(legacy.units, const {});
      expect([for (final p in pages.first.pages) p.rawPage], [8, 9, 10, 11, 12, 13]);
      expect(pages.first.pages.any(pages.first.isConceptPage), isFalse, reason: '문항 기록이 없으면 개념 페이지로 표시하지 않는다');

      ConceptBookEntry row(String? type, String? series) => ConceptBookEntry.fromMetadataRow({
            'academy_id': _academy,
            'book_id': _book,
            'grade_label': '1-1',
            'textbook_type': type,
            'payload': {if (series != null) 'series': series, 'units': const []},
          });
      expect(row(null, 'gaeyu').isConceptBook, isTrue, reason: '종류가 비어 있어도 개념서 시리즈면 개념서');
      expect(row(null, 'gaeyu').seriesName, '개념+유형');
      expect(row('문제집', 'wonri').isConceptBook, isTrue);
      expect(row('문제집', 'wonri').textbookType, '문제집', reason: '저장된 종류는 바꾸지 않는다');
      expect(row(null, 'rpm').isConceptBook, isFalse);
      expect(row(null, null).isConceptBook, isFalse);
    });

    test('실제 소단원 목록이 없으면 문항 묶음 칸을 보이되 개념 페이지로 표시하지 않는다', () {
      final units = conceptBookUnitsFromPayload({
        'series': 'gaeyu',
        'units': [
          {
            'name': 'I. 수와 연산',
            'middles': [
              {
                'name': '1. 소인수분해',
                'smalls': [
                  {'sub_key': 'A', 'start_page': 8, 'end_page': 9},
                  {'sub_key': 'B', 'name': '필수 문제', 'start_page': 10, 'end_page': 11},
                ],
              },
            ],
          },
        ],
      });
      expect([for (final u in units) u.path.last], ['개념확인', '필수 문제'], reason: '이름이 비면 시리즈의 칸 이름을 쓴다');
      expect(units.every((u) => u.slot), isTrue);
      final pages = conceptBookUnitPages(units, {9: const ConceptBookCropPage(problems: 4)});
      expect(pages.first.extracted, isTrue);
      expect(pages.first.pages.any(pages.first.isConceptPage), isFalse);
      expect(pages.first.pages.last.problems, 4);
    });

    testWidgets('예전 항목도 단원을 보이고, 이름·학년이 같고 문항 기록이 있는 항목으로 옮겨 볼 수 있다', (tester) async {
      final legacy = ConceptBookEntry.fromMetadataRow({
        'academy_id': _academy,
        'book_id': _book,
        'grade_label': '1-1',
        'textbook_type': '개념서',
        'payload': _legacyPayload(),
      }, bookName: '개념+유형');
      final registered = ConceptBookEntry.fromMetadataRow({
        'academy_id': _academy,
        'book_id': _book2,
        'grade_label': '1-1',
        'textbook_type': null,
        'payload': {
          'version': 2,
          'series': 'gaeyu',
          'units': [
            {
              'name': 'I. 수와 연산',
              'middles': [
                {
                  'name': '1. 소인수분해',
                  'smalls': [
                    {'sub_key': 'A', 'start_page': 8, 'end_page': 13},
                  ],
                  'sub_units': [
                    {'name': '소인수분해', 'start_page': 8, 'end_page': 13},
                    {'name': '최대공약수와 최소공배수', 'start_page': 14, 'end_page': 20},
                  ],
                },
              ],
            },
          ],
        },
      }, bookName: '개념+유형');
      final problemBook = ConceptBookEntry.fromMetadataRow({
        'academy_id': _academy,
        'book_id': _book3,
        'grade_label': '1-1',
        'textbook_type': null,
        'payload': {'series': 'rpm', 'units': const []},
      }, bookName: 'RPM 중1-1');
      final svc = _FakeBookService([
        registered,
        legacy,
        problemBook
      ], {
        registered.key: {9: const ConceptBookCropPage(problems: 3)},
      });
      final backend = _FakeBackend();

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ConceptBookDialog(library: _controller(backend), service: svc)),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('개념+유형'), findsOneWidget, reason: '문항 기록 없는 예전 항목은 숨긴다');
      expect(find.text('RPM 중1-1'), findsNothing);
      expect(find.text('개념+유형 시리즈'), findsOneWidget, reason: '종류가 비어 있는 시리즈 항목도 개념서로 보인다');
      expect(find.text('소단원 2개 · 문항 기록 3개'), findsOneWidget);
      expect(find.text('같은 교재의 문항 기록 없는 예전 항목 1개 숨김'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('concept-book-superseded-toggle')));
      await tester.pump();
      expect(find.text('개념+유형'), findsNWidgets(2));
      expect(find.text('소단원 3개 · 문항 기록 없음'), findsOneWidget);

      await tester.tap(find.text('소단원 3개 · 문항 기록 없음'));
      await tester.pump();
      await tester.pump();
      expect(find.text('단원마무리'), findsOneWidget, reason: '예전 항목도 저장된 소단원을 그대로 보인다');
      expect(find.text('이 교재 항목에는 문항 기록이 없어 개념 페이지를 표시하지 않습니다.'), findsOneWidget);
      expect(find.text('8쪽'), findsOneWidget);
      expect(find.textContaining('쪽 · 개념 페이지'), findsNothing);

      await tester.tap(find.text('문항 기록이 3개인 항목 보기'));
      await tester.pump();
      await tester.pump();
      expect(find.text('8쪽 · 개념 페이지'), findsOneWidget);
      expect(find.text('9쪽 · 문항 3개'), findsOneWidget);
      expect(find.text('14쪽'), findsOneWidget, reason: '문항 기록이 없는 소단원은 표시하지 않는다');
      expect(backend.writes, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('작은 창(800×600)에서도 창 아래 버튼 줄이 넘치지 않는다', (tester) async {
      final entry = ConceptBookEntry.fromMetadataRow({
        'academy_id': _academy,
        'book_id': _book,
        'grade_label': '1-1',
        'textbook_type': '개념서',
        'payload': _legacyPayload(),
      }, bookName: '개념+유형');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ConceptBookDialog(library: _controller(_FakeBackend()), service: _FakeBookService([entry], const {})),
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('개념+유형'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Think 대화에 쪽 이미지 붙이기'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('고른 쪽을 출처로 이을 때 저장된 교재 값만 쓰고, 같은 쪽은 두 번 잇지 않는다', () async {
      final backend = _FakeBackend();
      final c = _controller(backend);
      final concept = _concept(_conceptA);
      c.selectConcept(concept);
      await _settle();
      expect(c.sourcesOf(_conceptA), isEmpty);

      final ok = await c.addSource(
        concept: concept,
        academyId: _academy,
        bookId: _book,
        gradeLabel: '고1',
        rawPage: 9,
        unitPath: const ['I. 다항식', '1. 다항식의 연산', '다항식의 덧셈과 뺄셈'],
      );
      expect(ok, isNull);
      expect(c.sourcesOf(_conceptA)!.single.displayPage, isNull);
      expect(c.sourcesOf(_conceptA)!.single.pageLabel, 'PDF 9쪽');

      final dup = await c.addSource(concept: concept, academyId: _academy, bookId: _book, gradeLabel: '고1', rawPage: 9);
      expect(dup, contains('이미'));
      expect(c.sourcesOf(_conceptA), hasLength(1));

      expect(
        await c.addSource(concept: _concept('tmp-1'), academyId: _academy, bookId: _book, gradeLabel: '고1', rawPage: 9),
        isNotNull,
        reason: '저장 전 개념에는 잇지 않는다',
      );
    });

    List<String> unitPath(String name) => ['I. 수와 연산', '1. 소인수분해', name];
    Map<String, dynamic> draftRow(String id, String unit, String status, {String book = _book}) => {
          'id': id,
          'academy_id': _academy,
          'book_id': book,
          'grade_label': '1-1',
          'unit_path': unitPath(unit),
          'status': status,
        };
    ConceptBookEntry legacyEntry() => ConceptBookEntry.fromMetadataRow({
          'academy_id': _academy,
          'book_id': _book,
          'grade_label': '1-1',
          'textbook_type': '개념서',
          'payload': _legacyPayload(),
        }, bookName: '개념+유형');

    test('초안 진행: 확정 > 검토 중 순으로 보고, 버림·다시 정리함·다른 교재는 세지 않는다', () {
      final cov = ConceptDraftCoverage.fromRows([
        draftRow('d-new', '최대공약수와 최소공배수', 'open'),
        draftRow('d-old', '최대공약수와 최소공배수', 'open'),
        draftRow('d-c', '소인수분해', 'confirmed'),
        draftRow('d-o', '소인수분해', 'open'),
        draftRow('d-x', '단원마무리', 'discarded'),
        draftRow('d-r', '단원마무리', 'replaced'),
        draftRow('d-b', '단원마무리', 'open', book: _book2),
      ]);
      final book = legacyEntry();
      expect(cov.unit(book, unitPath('소인수분해')).state, ConceptUnitDraftState.confirmed);
      final open = cov.unit(book, unitPath('최대공약수와 최소공배수'));
      expect(open.state, ConceptUnitDraftState.open);
      expect(open.openId, 'd-new', reason: '가장 최근에 만든 검토 중 초안');
      expect(open.openCount, 2);
      expect(cov.unit(book, unitPath('단원마무리')).state, ConceptUnitDraftState.none);
      final p = cov.progress(book);
      expect((p.total, p.confirmed, p.open, p.remaining, p.percent), (3, 1, 1, 1, 66));
      expect(
        ConceptDraftCoverage.fromRows([
          draftRow('a', '소인수분해', 'open'),
          draftRow('b', '최대공약수와 최소공배수', 'confirmed'),
          draftRow('c', '단원마무리', 'open'),
        ]).progress(book).percent,
        100,
      );
      expect(
        conceptDraftableUnit(const ConceptBookUnit(path: ['x'], startPage: 1, endPage: 2, isExercise: true)),
        isFalse,
        reason: '연습문제·문항 묶음·쪽 범위 없는 소단원은 분모에 넣지 않는다',
      );
    });

    testWidgets('개념책 창: 교재·단원별 진행률과 소단원 초안 상태를 보이고, 검토 중이면 그 초안을 연다', (tester) async {
      final entry = legacyEntry();
      final drafts = _FakeCoverageService(ConceptDraftCoverage.fromRows([
        draftRow('d-new', '최대공약수와 최소공배수', 'open'),
        draftRow('d-c', '소인수분해', 'confirmed'),
        draftRow('d-x', '단원마무리', 'discarded'),
      ]));
      String? opened;
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showConceptBookDialog(
                context,
                library: _controller(_FakeBackend()),
                service: _FakeBookService([entry], const {}),
                draftService: drafts,
                onDraftReady: (id) => opened = id,
                orderLoader: (_) async => const ConceptBookOrder([]),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pump();
      await tester.pump();
      expect(find.text('초안 66% · 2/3'), findsOneWidget);

      await tester.tap(find.text('개념+유형'));
      await tester.pump();
      await tester.pump();
      expect(find.text('66%'), findsOneWidget);
      expect(find.text('소단원 3개 중 2개'), findsOneWidget);
      expect(find.text('확정 1'), findsOneWidget);
      expect(find.text('검토 중 1'), findsOneWidget);
      expect(find.text('아직 안 함 1'), findsOneWidget);
      expect(find.text('초안 2/3'), findsOneWidget, reason: '중단원 머리에도 진행을 보인다');
      expect(find.text('초안 확정함'), findsOneWidget);
      expect(find.text('초안 검토 중'), findsOneWidget);
      expect(find.text('초안 안 함'), findsOneWidget);
      expect(find.text('다시 만들기'), findsOneWidget);
      expect(find.text('검토하기'), findsOneWidget);
      expect(find.text('개념 초안 만들기'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('concept-book-order')));
      await tester.pumpAndSettle();
      expect(find.textContaining('이 교재를 출처로 이은 개념이 없습니다'), findsOneWidget);
      await tester.tap(find.byTooltip('닫기').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('이 교재를 출처로 이은 개념이 없습니다'), findsNothing);

      await tester.tap(find.text('초안 안 한 소단원만'));
      await tester.pump();
      expect(find.text('단원마무리'), findsOneWidget);
      expect(find.text('최대공약수와 최소공배수'), findsNothing);
      expect(find.text('초안 2/3'), findsOneWidget, reason: '거른 뒤에도 단원 진행은 전체 기준');

      await tester.tap(find.text('초안 안 한 소단원만'));
      await tester.pump();
      expect(find.text('새로 만들기'), findsNothing);
      expect(find.text('개념 추가하기'), findsNothing);
      await tester.tap(find.byIcon(Icons.check_box_outline_blank));
      await tester.pump();
      expect(find.text('중단원 1개 · 새로 만들 소단원 1개'), findsOneWidget, reason: '초안이 있는 소단원은 빼고 센다');
      expect(find.text('새로 만들기'), findsOneWidget);
      expect(find.text('개념 추가하기'), findsOneWidget);
      await tester.tap(find.text('고르기 취소'));
      await tester.pump();
      await tester.tap(find.text('검토하기'));
      await tester.pumpAndSettle();
      expect(opened, 'd-new');
      expect(find.text('개념책 불러오기'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('작업 공간 화면', () {
    (FakeCourseMapBackend, String, CourseMapController) courseMap() {
      final b = FakeCourseMapBackend();
      final id = b.addCourse('공통수학1', units: const [
        U('다항식', [
          U('다항식의 연산', [U('덧셈과 뺄셈'), U('곱셈')]),
        ]),
      ]);
      return (b, id, CourseMapController.forTest(b));
    }

    Finder nameField(String text) => find.byWidgetPredicate((w) => w is TextField && w.controller?.text == text);

    Future<void> pumpWorkspace(WidgetTester tester, ConceptLibraryController c,
        {double width = 1400, Widget? chat, CourseMapController? course}) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final map = course ?? courseMap().$3;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: 760,
            child: ConceptWorkspace(
              controller: c,
              courseDetail: CourseMapPane(controller: map),
              courseSummary: CourseMapSummaryPane(
                controller: map,
                onExpand: () => c.setFocus(ConceptWorkspaceFocus.courseMap),
              ),
              libraryDetail: LibraryDetailPane(
                tree: const Center(child: Text('개념 트리')),
                detail: ConceptDetailView(controller: c, onEdit: (_) {}, onPickForChat: (_) {}),
              ),
              librarySummary: LibrarySummaryPane(controller: c, onOpenConcept: (_) {}),
              chat: chat,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    Future<void> pumpFor(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('크게 보기로 오가도 흐름의 선택·저장 안 한 입력이 남고, 저장하지 않는다', (tester) async {
      final backend = _FakeBackend();
      final c = _controller(backend);
      await c.loadCriteria();
      c.selectConcept(_concept(_conceptA));
      c.setFocus(ConceptWorkspaceFocus.courseMap);
      final (courses, courseId, map) = courseMap();
      await pumpWorkspace(tester, c, course: map);
      await pumpFor(tester);

      final ops = courses.unitId(courseId, '다항식의 연산');
      await tester.tap(find.byKey(ValueKey('course-unit-$ops')));
      await tester.pump();
      await tester.enterText(nameField('다항식의 연산'), '다항식의 계산');
      await pumpFor(tester);
      expect(find.text('저장 안 됨 1'), findsOneWidget);

      await tester.tap(find.text('크게 보기'));
      await pumpFor(tester);
      expect(c.focus, ConceptWorkspaceFocus.library);
      expect(find.textContaining('저장하지 않은 변경 1곳'), findsOneWidget, reason: '왼쪽은 흐름 요약');
      expect(find.text('다항식의 계산'), findsOneWidget);
      expect(find.text('개념 트리'), findsOneWidget);

      await tester.tap(find.text('크게 보기'));
      await pumpFor(tester);
      expect(c.focus, ConceptWorkspaceFocus.courseMap);
      expect(map.draft!.selectedId, ops);
      expect(nameField('다항식의 계산'), findsOneWidget, reason: '접혀 있는 동안에도 입력이 남는다');
      expect(c.selectedConcept?.id, _conceptA);
      expect(courses.writes, 0);
      expect(backend.writes, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('개념 상세의 이은 기준을 누르면 그 기준이 골라지고 기준 창을 연다(칸은 그대로)', (tester) async {
      final backend = _FakeBackend();
      final first = backend.seed(title: '지식 분류', body: '네 가지', version: 1);
      final second = backend.seed(draftTitle: '대표 용어', draftBody: '교과서 용어');
      backend.links[second] = {_conceptA};
      backend.conceptNames[_conceptA] = '소인수분해';
      final c = _controller(backend);
      await c.loadCriteria();
      c.selectCriterion(first);
      c.selectConcept(_concept(_conceptA));
      await tester.pump();
      await pumpWorkspace(tester, c);
      await pumpFor(tester);

      expect(find.byTooltip('정리 기준 창에서 열기'), findsOneWidget, reason: '실제로 이은 기준만 보인다');
      await tester.tap(find.byTooltip('정리 기준 창에서 열기'));
      await pumpFor(tester);
      expect(c.focus, ConceptWorkspaceFocus.library);
      expect(c.selectedCriterionId, second);
      expect(c.criteriaDialogRequest.value, 1);
      expect(backend.writes, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('정리 기준 창은 닫았다 열어도 입력이 남고, 이은 개념을 열면 창이 닫힌다', (tester) async {
      final backend = _FakeBackend();
      final id = backend.seed(draftTitle: '관계 정의', draftBody: '');
      backend.links[id] = {_conceptA};
      backend.conceptNames[_conceptA] = '소인수분해';
      final c = _controller(backend);
      await c.loadCriteria();
      c.selectCriterion(id);
      String? opened;
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showConceptCriteriaDialog(ctx, controller: c, onOpenConcept: (x) => opened = x),
              child: const Text('기준 열기'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('기준 열기'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byWidgetPredicate((w) => w is TextField && w.controller == c.editOf(id).body), '먼저 알아야 하는 개념');
      await tester.tap(find.byTooltip('닫기(입력은 남음)'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('criterion-editor-$id')), findsNothing);

      await tester.tap(find.text('기준 열기'));
      await tester.pumpAndSettle();
      expect(_fieldOf(tester, c.editOf(id).body).controller!.text, '먼저 알아야 하는 개념');
      await tester.ensureVisible(find.byTooltip('라이브러리에서 열기', skipOffstage: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('라이브러리에서 열기'));
      await tester.pumpAndSettle();
      expect(opened, _conceptA);
      expect(find.byKey(ValueKey('criterion-editor-$id')), findsNothing);
      expect(c.editOf(id).body.text, '먼저 알아야 하는 개념');
      expect(backend.writes, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('좁은 화면에서는 한 칸씩 보고, 칸을 바꿔도 흐름 입력이 남는다', (tester) async {
      final backend = _FakeBackend();
      final c = _controller(backend);
      await c.loadCriteria();
      c.setFocus(ConceptWorkspaceFocus.courseMap);
      final (courses, courseId, map) = courseMap();
      await pumpWorkspace(tester, c, width: 720, chat: const Center(child: Text('대화 자리')), course: map);
      await pumpFor(tester);

      expect(find.text('Think 대화'), findsOneWidget, reason: '대화를 옆에 둘 자리가 없으면 칸으로 본다');
      final ops = courses.unitId(courseId, '다항식의 연산');
      await tester.tap(find.byKey(ValueKey('course-unit-$ops')));
      await tester.pump();
      await tester.enterText(nameField('다항식의 연산'), '다항식의 계산');
      await tester.tap(find.text('개념 라이브러리'));
      await pumpFor(tester);
      expect(find.text('개념 트리'), findsOneWidget);
      await tester.tap(find.text('Think 대화'));
      await pumpFor(tester);
      expect(find.text('대화 자리'), findsOneWidget);
      await tester.tap(find.text('교육과정 흐름'));
      await pumpFor(tester);
      expect(nameField('다항식의 계산'), findsOneWidget);
      expect(map.draft!.dirty, isTrue);
      expect(courses.writes, 0);
      expect(backend.writes, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('출처 표시를 눌러도 전환되거나 입력이 사라지지 않는다', (tester) async {
      final backend = _FakeBackend();
      final id = backend.seed(draftTitle: '확정 사례', draftBody: '');
      backend.sources[_conceptA] = [
        const ConceptSourceRef(
          id: 'src-1',
          conceptId: _conceptA,
          academyId: _academy,
          bookId: _book,
          gradeLabel: '고1',
          rawPage: 12,
          displayPage: 10,
          bookName: '개념원리 공통수학1',
          unitPath: ['I. 다항식', '1. 다항식의 연산'],
        ),
      ];
      final c = _controller(backend);
      await c.loadCriteria();
      c.editOf(id).body.text = '저장 전 입력';
      c.selectConcept(_concept(_conceptA));
      await tester.pump();
      await pumpWorkspace(tester, c);
      await pumpFor(tester);

      expect(find.text('출처 1개'), findsOneWidget);
      await tester.tap(find.text('출처 1개'));
      await pumpFor(tester);
      expect(find.text('개념원리 공통수학1'), findsOneWidget);
      expect(find.text('10쪽 (PDF 12쪽)'), findsOneWidget);
      expect(find.text('원본 열기'), findsOneWidget);
      expect(c.focus, ConceptWorkspaceFocus.library);

      await tester.tap(find.text('닫기'));
      await pumpFor(tester);
      expect(c.focus, ConceptWorkspaceFocus.library);
      expect(c.editOf(id).body.text, '저장 전 입력');
      expect(find.text('연결된 기준 없음'), findsOneWidget, reason: '개념 상세에 이은 기준이 없다고 보인다');
      expect(backend.writes, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('개념 상세에 초안 확정 때 붙은 유형을 보이고, 유형이 없으면 보이지 않는다', (tester) async {
      final backend = _FakeBackend()..conceptTypes[_conceptA] = '성질';
      final c = _controller(backend);
      await c.loadCriteria();
      c.selectConcept(_concept(_conceptA));
      await tester.pump();
      await pumpWorkspace(tester, c);
      await pumpFor(tester);
      expect(find.text('유형: 성질'), findsOneWidget);

      c.selectConcept(_concept('7a1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4c', name: '거듭제곱'));
      await pumpFor(tester);
      expect(find.textContaining('유형: '), findsNothing);
      expect(backend.writes, 0);
    });
  });
}
