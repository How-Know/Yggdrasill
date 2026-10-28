import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_action_cards.dart';
import 'package:yggdrasill_manager/services/think/think_action_models.dart';
import 'package:yggdrasill_manager/services/think/think_controller.dart';

const _poly = '다항식';
const _ops = '다항식 › 다항식의 연산';
const _add = '다항식 › 다항식의 연산 › 덧셈과 뺄셈';
const _mul = '다항식 › 다항식의 연산 › 곱셈';

ThinkAction _action(
  String id,
  String kind, {
  String status = 'proposed',
  Map<String, dynamic>? payload,
  Map<String, dynamic>? preview,
  Map<String, dynamic>? result,
  String? error,
}) =>
    ThinkAction.fromRow({
      'id': id,
      'conversation_id': 'c1',
      'kind': kind,
      'status': status,
      'payload': payload ?? {},
      'preview': preview ?? {},
      'result': result,
      'error': error,
      'superseded': false,
      'created_at': '2026-10-23T01:00:00Z',
    })!;

Map<String, dynamic> _placementPreview() => {
      'title': '개념 배치',
      'course_id': 'C1',
      'course_name': '공통수학1',
      'units': [
        {'id': 'u1', 'depth': 1, 'path': _poly},
        {'id': 'u2', 'depth': 2, 'path': _ops},
        {'id': 'u3', 'depth': 3, 'path': _add},
        {'id': 'u4', 'depth': 3, 'path': _mul},
      ],
      'counts': {'place': 2, 'move': 1, 'remove': 0, 'reorder': 0},
      'judgment': 1,
      'reason': '교재 출처의 단원 이름을 따랐습니다.',
      'items': [
        {
          'i': 1,
          'op': 'place',
          'concept_id': 'k1',
          'concept_name': '다항식의 덧셈',
          'type': '정의',
          'unit_id': 'u3',
          'unit_path': _add,
          'basis': 'source',
          'evidence': '교재 1단원 "다항식의 덧셈과 뺄셈"',
          'elsewhere': [],
        },
        {
          'i': 2,
          'op': 'place',
          'concept_id': 'k2',
          'concept_name': '곱셈 공식',
          'type': '공식',
          'unit_id': 'u3',
          'unit_path': _add,
          'basis': 'judgment',
          'evidence': '이름으로 판단',
          'elsewhere': [
            {'id': 'p9', 'course_id': 'C2', 'unit_id': 'x', 'path': '공통수학2 › 도형의 방정식'},
          ],
        },
        {
          'i': 3,
          'op': 'move',
          'placement_id': 'p1',
          'concept_id': 'k3',
          'concept_name': '항등식',
          'from_path': _mul,
          'unit_id': 'u1',
          'unit_path': _poly,
          'evidence': '나머지정리 앞 단원',
        },
      ],
    };

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 900, height: 1200, child: SingleChildScrollView(child: child)),
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, ThinkAction a) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1300));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_host(ThinkActionCard(action: a)));
}

void main() {
  testWidgets('지난 반영 실패가 카드에 남아 있으면 다시 승인할 수 있다고 알린다', (tester) async {
    final a = _action(
      'a-fail',
      'concept_placement_change',
      payload: {'course_id': 'C1'},
      preview: _placementPreview(),
      error: 'course_think_all_failed:concept_think_stale',
    );
    await _pump(tester, a);
    expect(find.textContaining('지난 승인에서 반영하지 못했습니다'), findsOneWidget);
    expect(find.textContaining('같은 카드를 다시 승인할 수 있습니다'), findsOneWidget);
    expect(find.text('고른 것 승인 (3)'), findsOneWidget);
  });

  group('개념 배치 카드', () {
    testWidgets('항목별 근거·판단 표시, 빼기와 단원 바꾸기, 고른 것만 승인 수에 든다', (tester) async {
      final a = _action('a1', 'concept_placement_change', payload: {'course_id': 'C1'}, preview: _placementPreview());
      await _pump(tester, a);

      expect(find.text('개념 배치 제안'), findsOneWidget);
      expect(find.text('"공통수학1" 단원에 개념 배치 3건'), findsOneWidget);
      expect(find.text('넣기 2 · 옮기기 1'), findsOneWidget);
      expect(find.text('출처 없이 판단 1'), findsOneWidget);
      expect(find.text('출처 없이 판단'), findsOneWidget, reason: '판단으로 놓은 항목에만');
      expect(find.text('교재 출처'), findsOneWidget);
      expect(find.text('→ $_add'), findsNWidgets(2));
      expect(find.text('$_mul → $_poly'), findsOneWidget);
      expect(find.textContaining('이미 놓인 곳: 공통수학2'), findsOneWidget);
      expect(find.textContaining('개념 본문·출처는 바뀌지 않습니다'), findsOneWidget);
      expect(find.text('고른 것 승인 (3)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('course-item-toggle-2')));
      await tester.pump();
      expect(find.text('고른 것 승인 (2)'), findsOneWidget);
      final unit2 = tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('course-item-unit-2')));
      expect(unit2.onPressed, isNull, reason: '뺀 항목은 단원을 바꾸지 않는다');

      await tester.tap(find.byKey(const ValueKey('course-item-unit-1')));
      await tester.pumpAndSettle();
      expect(find.text('"다항식의 덧셈" 단원 고르기'), findsOneWidget);
      expect(find.text('Think 제안'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('곱셈')));
      await tester.pumpAndSettle();
      expect(find.text('→ $_mul'), findsOneWidget);
      expect(find.textContaining('단원을 바꿔 승인합니다(Think 제안: $_add)'), findsOneWidget);

      await tester.tap(find.text('제안대로'));
      await tester.pump();
      expect(find.text('→ $_add'), findsNWidgets(2));
      expect(find.textContaining('단원을 바꿔 승인합니다'), findsNothing);

      await tester.tap(find.text('모두 고르기'));
      await tester.pump();
      expect(find.text('고른 것 승인 (3)'), findsOneWidget);
      await tester.tap(find.text('모두 빼기'));
      await tester.pump();
      expect(find.text('고른 것 승인 (0)'), findsOneWidget);
      final approve = tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('course-think-approve-a1')));
      expect(approve.onPressed, isNull, reason: '하나도 고르지 않으면 승인할 수 없다');
      expect(tester.takeException(), isNull);
    });

    testWidgets('승인된 카드는 반영·못 함·뺌 수와 못 한 이유를 남긴다', (tester) async {
      final a = _action('a1', 'concept_placement_change',
          status: 'applied',
          payload: {'course_id': 'C1'},
          preview: _placementPreview(),
          result: {
            'course_id': 'C1',
            'applied': 1,
            'failed': 1,
            'skipped': 1,
            'items': [
              {'i': 1, 'status': 'applied', 'placement_id': 'p7', 'unit_id': 'u3'},
              {'i': 2, 'status': 'skipped'},
              {'i': 3, 'status': 'failed', 'code': 'course_placement_exists'},
            ],
          });
      await _pump(tester, a);
      expect(find.text('개념 배치 "공통수학1" · 반영 1개 · 못 함 1개 · 뺌 1개'), findsOneWidget);
      expect(find.text('3. 옮기기 항등식: 이미 그 단원에 놓여 있음'), findsOneWidget);
      expect(find.textContaining('곱셈 공식:'), findsNothing, reason: '뺀 항목은 실패로 보이지 않는다');
      expect(find.text('거절'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('개념 고치기 카드', () {
    Map<String, dynamic> preview() => {
          'title': '개념 고치기',
          'counts': {'create': 1, 'edit': 0, 'statement': 1, 'delete': 2},
          'blocked': 1,
          'reason': '정리 요청',
          'items': [
            {
              'i': 1,
              'op': 'create',
              'name': '나머지정리',
              'type': '정리',
              'folder': ['수학', '공통수학1', '나머지정리'],
              'new_from': 3,
              'content': r'다항식 $f(x)$를 $x-a$로 나눈 나머지는 $f(a)$이다.',
              'place': {'unit_id': 'u2', 'path': _ops},
              'evidence': '교재 2단원',
              'same_name': [
                {'id': 'k5', 'name': '나머지정리', 'folder': ['수학', '대수']},
              ],
            },
            {
              'i': 2,
              'op': 'statement',
              'statement_id': 's1',
              'concept_id': 'k1',
              'concept_name': '다항식의 덧셈',
              'role': 'statement',
              'version': 2,
              'before': {'title': '덧셈', 'basis': 'verbatim'},
              'after': {'title': '다항식의 덧셈', 'basis': 'organized'},
            },
            {
              'i': 3,
              'op': 'delete',
              'concept_id': 'k8',
              'name': '옛 개념',
              'type': '정의',
              'folder': ['수학', '정리 안 됨'],
              'excerpt': '쓰지 않는 개념',
              'attached': {'sources': 2, 'placements': 1, 'total': 3},
              'blocked': true,
            },
            {
              'i': 4,
              'op': 'delete',
              'concept_id': 'k9',
              'name': '빈 개념',
              'folder': ['수학'],
              'excerpt': '',
              'attached': {'total': 0},
              'blocked': false,
            },
          ],
        };

    testWidgets('붙은 것이 있는 지우기는 처음부터 빠지고 고를 수 없다. 같은 이름은 알리기만 한다', (tester) async {
      await _pump(tester, _action('a2', 'concept_library_change', preview: preview()));

      expect(find.text('개념 고치기 제안'), findsOneWidget);
      expect(find.text('만들기 1 · 서술 고치기 1 · 지우기 2'), findsOneWidget);
      expect(find.textContaining('지울 수 없는 개념 1개'), findsOneWidget);
      expect(find.textContaining('붙은 것: 출처 2 · 기준 단원 자리 1'), findsOneWidget);
      expect(find.text('지울 수 없음'), findsOneWidget);
      expect(find.text('고른 것 승인 (3)'), findsOneWidget, reason: '막힌 항목은 처음부터 빠져 있다');

      await tester.tap(find.byKey(const ValueKey('course-item-toggle-3')));
      await tester.pump();
      expect(find.text('고른 것 승인 (3)'), findsOneWidget, reason: '막힌 항목은 다시 고를 수 없다');

      expect(find.text('폴더: 수학 › 공통수학1 › 나머지정리 (끝 1단계는 새 폴더)'), findsOneWidget);
      expect(find.text('놓을 단원: $_ops'), findsOneWidget);
      expect(find.textContaining('같은 이름의 개념이 이미 있습니다: 나머지정리 (수학 › 대수)'), findsOneWidget);
      expect(find.textContaining('이름이 같다고 같은 개념은 아니니'), findsOneWidget);
      expect(find.text('서술 v2'), findsOneWidget);
      expect(find.text('제목: 덧셈 → 다항식의 덧셈'), findsOneWidget);
      expect(find.text('근거: 원문 그대로 → 정리함'), findsOneWidget);
      expect(find.textContaining('고친 기록에 "Think 카드 승인: 이유"'), findsOneWidget);

      await tester.tap(find.text('본문 보기'));
      await tester.pump();
      expect(find.text('접기'), findsOneWidget);

      await tester.tap(find.text('모두 빼기'));
      await tester.pump();
      expect(find.text('고른 것 승인 (0)'), findsOneWidget);
      await tester.tap(find.text('모두 고르기'));
      await tester.pump();
      expect(find.text('고른 것 승인 (3)'), findsOneWidget, reason: '모두 고르기에도 막힌 항목은 들지 않는다');
      expect(tester.takeException(), isNull);
    });
  });

  group('개념 검토 기록 카드', () {
    final longFindings = '서술 1의 조건 칸과 본문의 적용 범위가 다르다. ' * 12;
    Map<String, dynamic> preview() => {
          'title': '개념 검토 기록',
          'counts': {'no_issue_found': 1, 'issue_found': 0, 'needs_comparison': 0, 'unverified': 0, 'merge_needed': 1},
          'reason': '다항식 폴더 검토',
          'items': [
            {
              'i': 1,
              'concept_id': 'k1',
              'name': '다항식의 덧셈',
              'type': '정의',
              'folder': ['수학', '다항식'],
              'scope': 'notation',
              'outcome': 'no_issue_found',
              'checked': '본문 전체와 서술 1의 표기',
              'findings': '오탈자를 찾지 못함',
              'basis': '본문 전체',
              'unverified': '서술 2의 용어 칸은 읽지 못함',
              'follow_up': null,
              'compared': [],
              'to_compare': [],
              'revision': 'aaaaaaaaaaaa-bbbbbbbbbbbb-cccccccccccc',
              'statements': [],
              'previous': {'outcome': 'issue_found', 'reviewed_at': '2026-10-20T03:00:00Z', 'stale': true},
              'pending_elsewhere': 1,
            },
            {
              'i': 2,
              'concept_id': 'k2',
              'name': '나머지정리',
              'type': null,
              'folder': ['수학'],
              'scope': 'unit',
              'outcome': 'merge_needed',
              'checked': '두 개념의 본문·출처',
              'findings': longFindings,
              'basis': '두 본문 비교',
              'unverified': null,
              'follow_up': '병합 방식은 사용자와 정한다',
              'compared': [
                {'id': 'k5', 'name': '나머지정리(대수)'},
              ],
              'to_compare': [
                {'id': 'k6', 'name': '인수정리'},
              ],
              'revision': 'dddddddddddd-eeeeeeeeeeee-ffffffffffff',
              'statements': [],
              'previous': null,
              'pending_elsewhere': 0,
            },
          ],
        };

    testWidgets('범위·결과·확인한 것·못 한 것·비교한 개념·앞선 기록을 보이고, 고른 것만 기록한다', (tester) async {
      await _pump(tester, _action('a5', 'concept_review_record', preview: preview()));

      expect(find.text('개념 검토 기록 제안'), findsOneWidget);
      expect(find.text('개념 검토 기록 2건'), findsOneWidget);
      expect(find.text('문제 못 찾음 1 · 병합 필요(삭제 보류) 1'), findsOneWidget);
      expect(find.text('오탈자·표기'), findsOneWidget);
      expect(find.text('중복·개념 단위'), findsOneWidget);
      expect(find.text('문제 못 찾음'), findsOneWidget);
      expect(find.text('병합 필요(삭제 보류)'), findsOneWidget);
      expect(find.textContaining('검증됨'), findsNothing, reason: '검증됐다는 결과는 없다');

      expect(find.text('정의 · 수학 › 다항식'), findsOneWidget);
      expect(find.text('유형 없음 · 수학'), findsOneWidget);
      expect(find.text('확인한 것: 본문 전체와 서술 1의 표기'), findsOneWidget);
      expect(find.text('찾은 것: 오탈자를 찾지 못함'), findsOneWidget);
      expect(find.text('확인 못 한 것: 서술 2의 용어 칸은 읽지 못함'), findsOneWidget);
      expect(find.text('앞선 기록: 문제 있음 (2026-10-20, 그 뒤 내용이 바뀜)'), findsOneWidget);
      expect(find.text('같은 개념·범위의 다른 검토 카드 1장이 승인 대기 중입니다.'), findsOneWidget);
      expect(find.text('비교한 개념: 나머지정리(대수)'), findsOneWidget);
      expect(find.text('더 비교할 개념: 인수정리'), findsOneWidget);
      expect(find.text('더 할 일: 병합 방식은 사용자와 정한다'), findsOneWidget);
      expect(find.textContaining('기록일 뿐 합치거나 지우지 않습니다'), findsOneWidget);
      expect(find.textContaining('"문제 못 찾음"은 검증됐다는 뜻이 아닙니다'), findsOneWidget);
      expect(find.textContaining('검토 기록이 붙은 개념은 지울 수 없게 됩니다'), findsOneWidget);

      expect(find.textContaining(longFindings), findsNothing, reason: '긴 글은 접어 둔다');
      await tester.tap(find.text('찾은 것 전체 보기'));
      await tester.pump();
      expect(find.text('접기'), findsOneWidget);

      expect(find.text('고른 것 승인 (2)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('course-item-toggle-1')));
      await tester.pump();
      expect(find.text('고른 것 승인 (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('통합 검수 범위(초등 기초 개념·교육과정 배치)와 함께 낸 고치기 카드를 보인다', (tester) async {
      final p = preview();
      final items = (p['items'] as List).cast<Map<String, dynamic>>();
      items[0] = {
        ...items[0],
        'scope': 'foundation',
        'outcome': 'issue_found',
        'fixes': [
          {'action_id': 'lib-1', 'kind': 'concept_library_change', 'items': [1]},
        ],
      };
      items[1] = {...items[1], 'scope': 'placement', 'outcome': 'no_issue_found'};
      await _pump(tester, _action('a6', 'concept_review_record', preview: p));

      expect(find.text('초등 기초 개념'), findsOneWidget);
      expect(find.text('교육과정 배치'), findsOneWidget);
      expect(
        find.text('고치기 제안: 함께 낸 개념 고치기 카드 1장. 그 카드를 승인해야 반영되고, 반영 뒤 이 범위를 다시 확인해야 완료입니다.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('승인된 카드는 남긴 수와 못 남긴 항목의 범위·이유를 보인다', (tester) async {
      await _pump(
        tester,
        _action('a5', 'concept_review_record', status: 'applied', preview: preview(), result: {
          'applied': 1,
          'failed': 1,
          'skipped': 0,
          'items': [
            {'i': 1, 'status': 'applied', 'review_id': 'r1', 'concept_id': 'k1'},
            {'i': 2, 'status': 'failed', 'code': 'concept_review_stale'},
          ],
        }),
      );
      expect(find.text('개념 검토 기록 · 반영 1개 · 못 함 1개'), findsOneWidget);
      expect(find.text('2. 중복·개념 단위 나머지정리: 제안한 뒤 개념 내용이 바뀜(다시 검토 필요)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('개념 관계 고치기 카드', () {
    Map<String, dynamic> end(String id, String name) => {
          'id': id,
          'name': name,
          'folder': ['도형', '넓이'],
        };
    Map<String, dynamic> preview() => {
          'title': '개념 관계 고치기',
          'counts': {'add': 1, 'change': 1, 'remove': 1},
          'reason': '넓이 단원 관계 정리',
          'items': [
            {
              'i': 1,
              'op': 'add',
              'relation_id': null,
              'from': end('k1', '정사각형의 넓이'),
              'to': end('k2', '직사각형의 넓이'),
              'before': null,
              'after': {'kind': 'depends_on', 'context': '넓이 공식을 증명할 때', 'basis': '교재 증명 문단', 'note': null},
              'uncertainty': '다른 교재에서는 따로 증명함',
              'reason': '증명에 직사각형 넓이를 씀',
              'open_same_concept_review': false,
              'pending_elsewhere': 1,
            },
            {
              'i': 2,
              'op': 'change',
              'relation_id': 'rel-2',
              'from': end('k3', '정사각형'),
              'to': end('k4', '직사각형'),
              'before': {
                'concept_id': 'k3',
                'related_id': 'k4',
                'kind': 'special_case',
                'context': null,
                'basis': null,
                'note': null,
                'rev': 1,
                'origin': 'draft',
                'decided': false,
              },
              'after': {'kind': 'kind_of', 'context': null, 'basis': '네 각이 직각인 사각형 중 네 변이 같음', 'note': null},
              'uncertainty': null,
              'reason': '종류 관계가 더 맞음',
              'open_same_concept_review': true,
              'pending_elsewhere': 0,
            },
            {
              'i': 3,
              'op': 'remove',
              'relation_id': 'rel-3',
              'from': end('k5', '꼭짓점'),
              'to': end('k6', '다각형'),
              'before': {
                'concept_id': 'k5',
                'related_id': 'k6',
                'kind': 'part_of',
                'context': null,
                'basis': '정의',
                'note': null,
                'rev': 2,
                'origin': 'manual',
                'decided': true,
              },
              'after': null,
              'uncertainty': null,
              'reason': '같은 관계가 다른 개념에 있음',
              'open_same_concept_review': false,
              'pending_elsewhere': 0,
            },
          ],
        };

    test('관계 카드는 항목 카드로 다룬다', () {
      final k = ThinkActionKind.parse('concept_relation_change');
      expect(k, ThinkActionKind.conceptRelationChange);
      expect(k!.isCourseThink, isTrue);
      expect(k.hasItems, isTrue);
    });

    testWidgets('두 개념·id·지금과 바꾼 뒤·방향·맥락·근거·불확실한 점·이유를 보이고, 고른 것만 승인 수에 든다', (tester) async {
      await _pump(tester, _action('a6', 'concept_relation_change', preview: preview()));

      expect(find.text('개념 관계 고치기 제안'), findsOneWidget);
      expect(find.text('개념 관계 고치기 3건'), findsOneWidget);
      expect(find.text('넣기 1 · 바꾸기 1 · 빼기 1'), findsOneWidget);

      expect(find.text('A(출발): 정사각형의 넓이 · 도형 › 넓이 · k1'), findsOneWidget);
      expect(find.text('B(기준): 직사각형의 넓이 · 도형 › 넓이 · k2'), findsOneWidget);
      expect(find.text('넣을 관계: 맥락 "넓이 공식을 증명할 때"에서: "정사각형의 넓이"을(를) 배우거나 쓰려면 "직사각형의 넓이"이(가) 필요'),
          findsOneWidget);
      expect(find.textContaining('"정사각형의 넓이"을(를) 배우거나 쓰려면 "직사각형의 넓이"이(가) 필요'), findsOneWidget,
          reason: '맥락 없는 선수 관계 문장은 따로 없다');
      expect(find.text('불확실한 점: 다른 교재에서는 따로 증명함'), findsOneWidget);
      expect(find.text('같은 관계나 두 개념을 다룬 다른 관계 카드 항목 1개가 승인 대기 중입니다.'), findsOneWidget);

      expect(find.text('지금: "정사각형"은(는) "직사각형"의 특수한 경우'), findsOneWidget);
      expect(find.text('바꾼 뒤: "정사각형"은(는) "직사각형"의 한 종류'), findsOneWidget);
      expect(find.text('지금 관계는 결정 기록이 없습니다(이 기능 전에 생긴 관계).'), findsOneWidget, reason: '빼기 항목은 기록이 있음');
      expect(find.textContaining('"같은 개념인지 검토 필요" 표시가 열려 있습니다'), findsOneWidget);

      expect(find.text('뺄 관계: "꼭짓점"은(는) "다각형"을(를) 이루는 요소'), findsOneWidget);
      expect(find.text('근거: 정의'), findsOneWidget);
      expect(find.text('관계만 빼고 두 개념은 그대로 둡니다. 뺀 일은 관계 이력에 남습니다.'), findsOneWidget);
      expect(find.textContaining('빼기는 관계만 지우고 개념은 그대로 둡니다'), findsOneWidget);
      expect(find.textContaining('그 관계를 다른 곳에서 고쳤으면 그 항목은 반영하지 않습니다'), findsOneWidget);

      expect(find.text('고른 것 승인 (3)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('course-item-toggle-3')));
      await tester.pump();
      expect(find.text('고른 것 승인 (2)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('승인된 카드는 반영·못 함·뺌 수와 못 한 항목의 두 개념·이유를 보인다', (tester) async {
      await _pump(
        tester,
        _action('a6', 'concept_relation_change', status: 'applied', preview: preview(), result: {
          'applied': 1,
          'failed': 1,
          'skipped': 1,
          'items': [
            {'i': 1, 'status': 'applied', 'op': 'add', 'relation_id': 'rel-9', 'concept_id': 'k1', 'related_id': 'k2'},
            {'i': 2, 'status': 'failed', 'code': 'concept_relation_concept_stale', 'concept_id': 'k3', 'related_id': 'k4'},
            {'i': 3, 'status': 'skipped'},
          ],
        }),
      );
      expect(find.text('개념 관계 고치기 · 반영 1개 · 못 함 1개 · 뺌 1개'), findsOneWidget);
      expect(find.text('2. 바꾸기 "정사각형" → "직사각형": 제안한 뒤 두 개념 중 하나의 글이 바뀜(다시 판단 필요)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('과정 카드', () {
    testWidgets('탐색도 고치기는 바뀔 것과 빠지는 개념 자리를 보이고, 항목 고르기 없이 승인한다', (tester) async {
      await _pump(
        tester,
        _action('a3', 'course_map_change', payload: {
          'course_id': 'C1',
          'course_action': 'units',
        }, preview: {
          'title': '과정 탐색도 고치기',
          'course_id': 'C1',
          'course_name': '공통수학1',
          'base_version': 4,
          'lines': [
            {'op': 'rename', 'text': '"다항식의 연산" → "다항식의 계산"'},
            {'op': 'archive', 'text': '"곱셈" 보관'},
          ],
          'archived_placements': 2,
          'reason': '교과서 목차에 맞춤',
        }),
      );
      expect(find.text('과정 탐색도 고치기 제안'), findsOneWidget);
      expect(find.text('판 v4 기준'), findsOneWidget);
      expect(find.text('· "다항식의 연산" → "다항식의 계산"'), findsOneWidget);
      expect(find.textContaining('개념 자리 2곳이 목록에서 빠집니다'), findsOneWidget);
      expect(find.text('승인'), findsOneWidget);
      expect(find.textContaining('고른 것 승인'), findsNothing);
      expect(find.byKey(const ValueKey('course-item-toggle-1')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('새 과정은 단원 나무와 수를 보이고, 승인된 뒤엔 한 줄로 줄인다', (tester) async {
      final preview = {
        'title': '새 과정',
        'name': '대수',
        'school_level': '고',
        'curriculum_code': 'rev_2022',
        'curriculum_label': '2022 개정',
        'units': [
          {'depth': 1, 'name': '지수함수와 로그함수'},
          {'depth': 2, 'name': '지수와 로그'},
          {'depth': 3, 'name': '거듭제곱근'},
        ],
        'counts': [1, 1, 1],
      };
      await _pump(tester, _action('a4', 'course_map_create', preview: preview));
      expect(find.text('새 과정 "대수"'), findsOneWidget);
      expect(find.text('고 · 2022 개정 · 대 1 · 중 1 · 소 1'), findsOneWidget);
      expect(find.text('거듭제곱근'), findsOneWidget);
      expect(find.textContaining('과정 목록 맨 끝에'), findsOneWidget);

      await tester.pumpWidget(_host(ThinkActionCard(
        key: const ValueKey('done'),
        action: _action('a4', 'course_map_create',
            status: 'applied', preview: preview, result: {'course_id': 'C9', 'units': 3}),
      )));
      expect(find.text('새 과정 "대수" · 만듦(단원 3개)'), findsOneWidget);
      expect(find.text('거듭제곱근'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  test('새 제안이 앞 제안을 대체하는 것은 같은 과정의 탐색도 고치기뿐이다', () {
    final c = ThinkController.instance;
    c.selectedId = 'c1';
    c.putActionForTest(_action('m1', 'course_map_change', payload: {'course_id': 'C1'}));
    c.putActionForTest(_action('m2', 'course_map_change', payload: {'course_id': 'C2'}));
    c.putActionForTest(_action('p1', 'concept_placement_change', payload: {'course_id': 'C1'}));
    c.putActionForTest(_action('l1', 'concept_library_change'));
    c.putActionForTest(_action('m3', 'course_map_change', payload: {'course_id': 'C1'}));
    c.putActionForTest(_action('p2', 'concept_placement_change', payload: {'course_id': 'C1'}));
    c.putActionForTest(_action('l2', 'concept_library_change'));
    c.putActionForTest(_action('r1', 'concept_review_record'));
    c.putActionForTest(_action('r2', 'concept_review_record'));
    c.putActionForTest(_action('x1', 'concept_relation_change'));
    c.putActionForTest(_action('x2', 'concept_relation_change'));
    final byId = {for (final a in c.actionsOf('c1')) a.id: a};
    expect(byId['m1']!.superseded, isTrue);
    expect(byId['m2']!.pending, isTrue, reason: '다른 과정은 그대로');
    expect(byId['m3']!.pending, isTrue);
    expect(byId['p1']!.pending, isTrue, reason: '배치 카드는 쌓인다');
    expect(byId['p2']!.pending, isTrue);
    expect(byId['l1']!.pending, isTrue, reason: '개념 고치기 카드도 쌓인다');
    expect(byId['l2']!.pending, isTrue);
    expect(byId['r1']!.pending, isTrue, reason: '검토 기록 카드도 쌓인다');
    expect(byId['r2']!.pending, isTrue);
    expect(byId['x1']!.pending, isTrue, reason: '관계 카드도 쌓인다');
    expect(byId['x2']!.pending, isTrue);
  });
}
