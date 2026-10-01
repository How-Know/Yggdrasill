import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_authoring_stage_dialog.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_toc_autofill.dart';
import 'package:yggdrasill_manager/services/textbook_series_catalog.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_answer_service.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_test_service.dart';

void main() {
  test('중등 개념원리 2단계 목차를 본문 소단원 범위로 보완한다', () async {
    final firstMid = TocAutofillMidUnit(name: '정수와 유리수')
      ..startPage = 50
      ..endPage = 69;
    final secondMid = TocAutofillMidUnit(name: '정수와 유리수의 계산')
      ..startPage = 70
      ..endPage = 103;
    final tree = <TocAutofillBigUnit>[
      TocAutofillBigUnit(name: '정수와 유리수')
        ..midUnits.addAll(<TocAutofillMidUnit>[firstMid, secondMid]),
    ];

    final report = await autofillWonriMiddleSubUnitRanges(
      tree,
      classify: (rawPages) async => <TextbookWonriMiddleStructurePage>[
        for (final page in rawPages)
          TextbookWonriMiddleStructurePage(
            rawPage: page,
            subUnitHeaderVisible: const <int>{50, 60, 70, 80}.contains(page),
            subUnitName: switch (page) {
              50 => '01 정수와 유리수',
              60 => '02 정수의 대소 관계',
              70 => '01 정수의 덧셈과 뺄셈',
              80 => '02 정수의 곱셈과 나눗셈',
              _ => '',
            },
            unitEndKind: const <int>{68, 100}.contains(page)
                ? 'review'
                : (const <int>{69, 102}.contains(page)
                    ? 'descriptive'
                    : 'none'),
            calculationHeaderVisible: const <int>{78, 94}.contains(page),
          ),
      ],
    );

    expect(report.completedMids, 2);
    expect(report.subUnitCount, 4);
    expect(report.calculationPageCount, 2);
    expect(report.incompleteMids, isEmpty);

    expect(
      firstMid.subUnits.map((sub) => sub.name).toList(),
      <String>['정수와 유리수', '정수의 대소 관계', '중단원 마무리하기'],
    );
    expect(
      firstMid.subUnits
          .map((sub) => <int?>[sub.startPage, sub.endPage])
          .toList(),
      <List<int?>>[
        <int?>[50, 59],
        <int?>[60, 67],
        <int?>[68, 69],
      ],
    );
    expect(
      secondMid.subUnits.map((sub) => sub.name).toList(),
      <String>['정수의 덧셈과 뺄셈', '정수의 곱셈과 나눗셈', '중단원 마무리하기'],
    );
    expect(
      secondMid.subUnits
          .map((sub) => <int?>[sub.startPage, sub.endPage])
          .toList(),
      <List<int?>>[
        <int?>[70, 79],
        <int?>[80, 99],
        <int?>[100, 103],
      ],
    );

    // F는 소단원 행을 만들지 않는다. 실제 문항 탐지 시에만 동적 슬롯으로 생긴다.
    expect(
      tree
          .expand((big) => big.midUnits)
          .expand((mid) => mid.subUnits)
          .any((sub) => sub.name == '계산력 강화하기'),
      isFalse,
    );
  });

  test('소단원 헤더가 불확실한 중단원은 임의 생성하지 않는다', () async {
    final mid = TocAutofillMidUnit(name: '미확정 중단원')
      ..startPage = 10
      ..endPage = 20;
    final tree = <TocAutofillBigUnit>[
      TocAutofillBigUnit(name: '대단원')..midUnits.add(mid),
    ];

    final report = await autofillWonriMiddleSubUnitRanges(
      tree,
      classify: (rawPages) async => <TextbookWonriMiddleStructurePage>[
        for (final page in rawPages)
          TextbookWonriMiddleStructurePage(
            rawPage: page,
            subUnitHeaderVisible: false,
            subUnitName: '',
            unitEndKind: 'none',
            calculationHeaderVisible: false,
          ),
      ],
    );

    expect(report.completedMids, 0);
    expect(report.incompleteMids, <String>['미확정 중단원']);
    expect(mid.subUnits, isEmpty);
  });

  test('wonri_middle 프로필은 A~E 고정·F 동적 슬롯을 사용한다', () {
    final entry = textbookSeriesByKey('wonri_middle');
    expect(entry, isNotNull);
    expect(entry!.hasSubUnitRows, isTrue);
    expect(entry.unitEndSlotKeys, <String>{'D', 'E'});
    expect(
      entry.subPreset.map((preset) => preset.key).toList(),
      <String>['A', 'B', 'C', 'D', 'E'],
    );
    expect(entry.subPreset.any((preset) => preset.key == 'F'), isFalse);
  });

  test('중단원 마무리 연속 지면은 D와 직전 STEP을 유지한다', () {
    TextbookVlmItem item({
      required String number,
      required String category,
      String label = '',
    }) =>
        TextbookVlmItem(
          number: number,
          label: label,
          category: category,
          isSetHeader: false,
          setFrom: null,
          setTo: null,
          contentGroupKind: 'none',
          contentGroupLabel: '',
          contentGroupTitle: '',
          contentGroupOrder: null,
          column: 1,
          bbox: const <int>[10, 10, 20, 20],
          itemRegion: const <int>[20, 10, 80, 400],
        );

    final guard = TextbookWonriMiddleUnitEndGuard();
    final first = guard.normalize(
      item(
        number: '01',
        category: 'middle_unit_review',
        label: 'STEP 1',
      ),
      pageSection: 'middle_unit_review',
    );
    final continuation = guard.normalize(
      item(number: '07', category: 'middle_exam_problem'),
      pageSection: 'middle_exam_problem',
    );
    final descriptive = guard.normalize(
      item(number: '01', category: 'middle_descriptive'),
      pageSection: 'middle_descriptive',
    );
    final descriptiveContinuation = guard.normalize(
      item(number: '02', category: 'middle_exam_problem'),
      pageSection: 'middle_exam_problem',
    );

    expect(first.category, 'middle_unit_review');
    expect(first.label, 'STEP1');
    expect(continuation.category, 'middle_unit_review');
    expect(continuation.label, 'STEP1');
    expect(descriptive.category, 'middle_descriptive');
    expect(descriptiveContinuation.category, 'middle_descriptive');
  });

  group('소단원 행 코너 복구', () {
    const concept = 'middle_concept_check';
    const core = 'middle_core_problem';
    const exam = 'middle_exam_problem';

    TextbookVlmItem item(String number, String category, [String role = '']) =>
        TextbookVlmItem(
          number: number,
          label: '',
          category: category,
          itemRole: role,
          isSetHeader: false,
          setFrom: null,
          setTo: null,
          contentGroupKind: category == core ? 'type' : 'none',
          contentGroupLabel: category == core ? '핵심문제 01' : '',
          contentGroupTitle: category == core ? '유형' : '',
          contentGroupOrder: null,
          column: 1,
          bbox: const <int>[10, 10, 20, 20],
          itemRegion: const <int>[20, 10, 80, 400],
        );

    List<String> sections(List<List<TextbookVlmItem>> pages) =>
        [for (final page in pages) page.first.category];

    test('핵심문제로 읽힌 확인하기 지면을 A로 되돌린다 (2-2 평행사변형 64쪽)', () {
      final pages = <List<TextbookVlmItem>>[
        [
          for (final n in ['01', '02', '03', '04'])
            item(n, core, 'representative')
        ],
        [item('01', core, 'representative'), item('확인 1', core, 'follow_up')],
        [item('02', core, 'representative'), item('확인 2', core, 'follow_up')],
        [item('01', exam), item('02', exam)],
      ];
      final out = repairWonriMiddleSubUnitCorners(
        pages,
        pageSections: sections(pages),
      );

      expect(out[0].map((i) => i.category).toSet(), <String>{concept});
      expect(out[0].map((i) => i.itemRole).toSet(), <String>{'standard'});
      expect(out[0].first.contentGroupKind, 'none');
      expect(identical(out[1], pages[1]), isTrue);
      expect(identical(out[3], pages[3]), isTrue);
    });

    test('B 뒤에서 A로 읽힌 시험문제 지면은 C로 보낸다', () {
      final pages = <List<TextbookVlmItem>>[
        [item('01', concept), item('02', concept)],
        [item('01', core, 'representative'), item('확인 1', core, 'follow_up')],
        [item('01', concept), item('02', concept), item('03', concept)],
      ];
      final out = repairWonriMiddleSubUnitCorners(
        pages,
        pageSections: sections(pages),
      );

      expect(identical(out[0], pages[0]), isTrue);
      expect(out[2].map((i) => i.category).toSet(), <String>{exam});
    });

    test('확인 문항이 다음 지면으로 넘어간 대표 예제는 건드리지 않는다', () {
      final pages = <List<TextbookVlmItem>>[
        [
          item('01', concept),
          item('02', concept),
          item('01', core, 'representative')
        ],
        [item('확인 1', core, 'follow_up'), item('02', core, 'representative')],
      ];
      final out = repairWonriMiddleSubUnitCorners(
        pages,
        pageSections: sections(pages),
      );

      expect(identical(out[0], pages[0]), isTrue);
      expect(identical(out[1], pages[1]), isTrue);
    });

    test('옮길 코너에 같은 번호가 이미 있으면 그대로 둔다', () {
      final pages = <List<TextbookVlmItem>>[
        [item('01', concept)],
        [item('01', core, 'representative')],
        [item('01', core, 'representative'), item('확인 1', core, 'follow_up')],
      ];
      final out = repairWonriMiddleSubUnitCorners(
        pages,
        pageSections: sections(pages),
      );

      expect(identical(out[1], pages[1]), isTrue);
    });
  });

  test('해설 기대 키에 코너·중단원·본문 쪽을 함께 보존한다', () {
    final expected = textbookExpectedAnswerFor(
      seriesKey: 'wonri_middle',
      problemNumber: '01',
      section: 'middle_calculation',
      displayPage: 78,
      midName: '정수와 유리수의 계산',
    );

    expect(textbookAnswerNeedsCorner('wonri_middle'), isTrue);
    expect(expected.number, '01');
    expect(expected.corner, '계산력 강화하기');
    expect(expected.blockTitle, '정수와 유리수의 계산');
    expect(expected.bodyPage, 78);
  });

  test('Stage 크롭 조회는 A~F를 소단원 sub_index로 격리한다', () {
    TextbookAuthoringStageScope scope(String subKey) =>
        TextbookAuthoringStageScope(
          bigOrder: 1,
          midOrder: 2,
          subKey: subKey,
          unitRowIndex: 3,
        );

    for (final subKey in <String>['A', 'B', 'C', 'D', 'E', 'F']) {
      expect(
        textbookStageCropSubIndexForScope(
          'wonri_middle',
          scope(subKey),
        ),
        3,
        reason: subKey,
      );
    }
  });

  test('중등 개념원리 예제와 후속 문항의 풀이 출처를 분리한다', () {
    expect(
      textbookWonriMiddleUsesBodySolution(
        section: 'middle_core_problem',
        problemNumber: '01',
        itemName: '핵심문제 대표 예제',
      ),
      isTrue,
    );
    expect(
      textbookWonriMiddleUsesBodySolution(
        section: 'middle_core_problem',
        problemNumber: '확인 1',
        itemName: '핵심문제 확인',
      ),
      isFalse,
    );
    expect(
      textbookWonriMiddleUsesBodySolution(
        section: 'middle_descriptive',
        problemNumber: '예제 1',
        itemName: '서술형 예시 문항',
      ),
      isTrue,
    );
    expect(
      textbookWonriMiddleUsesBodySolution(
        section: 'middle_descriptive',
        problemNumber: '유제 1',
        itemName: '서술형 대비 문제',
      ),
      isFalse,
    );
    expect(textbookWonriMiddlePrintedNumberKey('확인 03'), '3');
    expect(textbookWonriMiddlePrintedNumberKey('유제 3'), '3');
    expect(
      textbookWonriMiddleStoredProblemNumber(
        section: 'middle_core_problem',
        problemNumber: '01',
        itemRole: 'follow_up',
      ),
      '확인 1',
    );
    expect(
      textbookWonriMiddleStoredProblemNumber(
        section: 'middle_descriptive',
        problemNumber: '01',
        itemRole: 'descriptive_example',
      ),
      '예제 1',
    );
    expect(
      textbookWonriMiddleStoredProblemNumber(
        section: 'middle_descriptive',
        problemNumber: '01',
        itemRole: 'follow_up',
      ),
      '유제 1',
    );
    expect(
      textbookWonriMiddleScanEnd(
        answers: true,
        scopeEnd: 2,
        pageCount: 88,
      ),
      2,
    );
    expect(
      textbookWonriMiddleScanEnd(
        answers: false,
        scopeEnd: 2,
        pageCount: 88,
      ),
      3,
    );
  });

  test('해설 판독 요청을 코너·소단원별 오름차순 묶음으로 나눈다', () {
    const sections = <String>[
      'middle_core_problem',
      'middle_core_problem',
      'middle_core_problem',
      'middle_core_problem',
      'middle_exam_problem',
    ];
    const scopes = <String>['1-1-A', '1-1-A', '1-2-A', '1-2-A', '1-1-A'];
    const numbers = <String>['확인 2', '확인 1', '확인 2', '확인 1', '01'];

    final batches = textbookWonriMiddleRequestBatches(
      order: <int>[0, 1, 2, 3, 4],
      sectionOf: (position) => sections[position],
      scopeKeyOf: (position) => scopes[position],
      numberOf: (position) => numbers[position],
    );

    // 같은 코너라도 소단원이 다르면 확인 1~2가 두 벌로 겹쳐 모델이 박스를
    // 특정하지 못한다. 묶음을 나누고 번호는 오름차순으로만 보낸다.
    expect(batches, <List<int>>[
      <int>[1, 0],
      <int>[3, 2],
      <int>[4],
    ]);
  });

  test('한 코너가 많으면 오름차순을 유지한 채 16개씩 나눈다', () {
    final batches = textbookWonriMiddleRequestBatches(
      order: <int>[for (var i = 23; i >= 0; i -= 1) i],
      sectionOf: (_) => 'middle_unit_review',
      scopeKeyOf: (_) => '1-1-D',
      numberOf: (position) => '${position + 1}',
    );

    expect(batches.length, 2);
    expect(batches.first, <int>[for (var i = 0; i < 16; i += 1) i]);
    expect(batches.last, <int>[for (var i = 16; i < 24; i += 1) i]);
  });

  test('같은 코너에서 뒤 번호가 잡혔으면 앞 누락분은 다음 지면에 묻지 않는다', () {
    // 2-1 중단원 마무리: 02~04를 놓친 채 05~11을 찾으면 31쪽 첫 풀이 12가
    // 목록 넷째로 밀려 이어진 풀이 전체가 버려졌다.
    final pending = <int>{1, 2, 3, for (var i = 11; i < 24; i += 1) i};
    final batches = textbookWonriMiddleRequestBatches(
      order: pending.toList()..sort(),
      sectionOf: (_) => 'middle_unit_review',
      scopeKeyOf: (_) => '1:1:D:2',
      numberOf: (position) => '${position + 1}'.padLeft(2, '0'),
      settled: <int>[
        for (var i = 0; i < 24; i += 1)
          if (!pending.contains(i)) i,
      ],
    );
    expect(batches, <List<int>>[
      <int>[for (var i = 11; i < 24; i += 1) i],
    ]);

    // 소단원 키가 없으면 다음 소단원의 01을 가를 수 없으므로 그대로 둔다.
    final unscoped = textbookWonriMiddleRequestBatches(
      order: <int>[0, 1],
      sectionOf: (_) => 'middle_unit_review',
      scopeKeyOf: (_) => '',
      numberOf: (position) => '0${position + 1}',
      settled: const <int>[2],
    );
    expect(unscoped, <List<int>>[
      <int>[0, 1],
    ]);
  });

  test('시작도 안 한 코너는 박스 없는 지면의 이어진 풀이를 가져가지 않는다', () {
    // 2-1 해설 24쪽: 23쪽 계산력(본문 64쪽) 박스에서 이어진 01~04를
    // 아직 박스가 안 나온 시험문제(본문 65쪽)가 차지했다. 모델은 23쪽
    // 계산력 배지를 70쪽으로 잘못 읽었다.
    const page23Boxes = <({String title, int? from, int? to})>[
      (title: '핵심문제 익히기', from: 62, to: 63),
      (title: '계산력 강화하기', from: 70, to: 70),
    ];
    expect(
      textbookWonriMiddleMayContinue(
        started: false,
        section: 'middle_exam_problem',
        previousPageBoxes: page23Boxes,
        bodyPages: const <int?>[65, 65],
      ),
      isFalse,
    );
    expect(
      textbookWonriMiddleMayContinue(
        started: false,
        section: 'middle_calculation',
        previousPageBoxes: page23Boxes,
        bodyPages: const <int?>[64],
        siblingBodyPages: const <int?>[72],
      ),
      isTrue,
    );
    // 25쪽 첫 소단원 시험문제 박스(본문 65쪽)는 둘째 소단원 시험문제(73쪽)의
    // 박스가 아니다.
    expect(
      textbookWonriMiddleMayContinue(
        started: false,
        section: 'middle_exam_problem',
        previousPageBoxes: const <({String title, int? from, int? to})>[
          (title: '이런 문제가 시험에 나온다', from: 65, to: 65),
        ],
        bodyPages: const <int?>[73],
        siblingBodyPages: const <int?>[65],
      ),
      isFalse,
    );
    // 앞 지면에서 이미 문항을 찾은 코너는 박스 없이도 이어진다(중단원 마무리 12~).
    expect(
      textbookWonriMiddleMayContinue(
        started: true,
        section: 'middle_unit_review',
        previousPageBoxes: const <({String title, int? from, int? to})>[],
        bodyPages: const <int?>[75, 76],
      ),
      isTrue,
    );
  });

  test('한 지면에서 앞뒤 번호 사이만 빠진 문항을 다시 묻는다', () {
    // 2-1 해설 34쪽 핵심문제 박스: 확인 1~6 중 둘째 줄 첫 칸 확인 5만 빠졌다.
    const numbers = <String>['확인 1', '확인 2', '확인 3', '확인 4', '확인 5', '확인 6'];
    expect(
      textbookWonriMiddlePageGaps(
        asked: const <int>[0, 1, 2, 3, 4, 5],
        stillPending: <int>{4},
        numberOf: (position) => numbers[position],
      ),
      <int>[4],
    );
    // 뒤쪽이 다음 지면으로 넘어간 것은 사이 누락이 아니다.
    expect(
      textbookWonriMiddlePageGaps(
        asked: const <int>[0, 1, 2, 3, 4, 5],
        stillPending: <int>{4, 5},
        numberOf: (position) => numbers[position],
      ),
      isEmpty,
    );
  });

  test('해설 지면의 같은 번호 자리는 한 문항만 차지한다', () {
    // 1-2 해설 20쪽 시험문제 01: 둘째·셋째 소단원 요청이 같은 자리를 돌려준다.
    expect(
      textbookRegionsOverlap(
        const <int>[588, 88, 603, 110],
        const <int>[589, 88, 604, 111],
      ),
      isTrue,
    );
    // 같은 단의 바로 아래 번호(02)는 다른 자리다.
    expect(
      textbookRegionsOverlap(
        const <int>[588, 88, 603, 110],
        const <int>[730, 88, 745, 110],
      ),
      isFalse,
    );
    expect(textbookRegionsOverlap(null, const <int>[0, 0, 10, 10]), isFalse);
  });
}
