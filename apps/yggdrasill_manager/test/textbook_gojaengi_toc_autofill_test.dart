import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_toc_autofill.dart';
import 'package:yggdrasill_manager/services/textbook_series_catalog.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_test_service.dart';

/// 고쟁이 2-2 중등판 실지면 기준.
///   중단원 02 삼각형의 외심과 내심 = p20~34
///   p20 개념 · p21 Step1 · p25 Step2(대표 문항+스키마) · p31 Step3 · p34 창의융합
void main() {
  test('고쟁이 목차는 2단계이고 중단원 줄에 시작 쪽이 인쇄된다', () {
    const toc = TextbookTocParseResult(
      bigUnits: <TextbookTocBigUnit>[
        TextbookTocBigUnit(
          name: '삼각형의 성질',
          midUnits: <TextbookTocMidUnit>[
            TextbookTocMidUnit(
              name: '이등변삼각형과 직각삼각형',
              page: 6,
              hasExercise: false,
              subUnits: <TextbookTocSubUnit>[],
            ),
            TextbookTocMidUnit(
              name: '삼각형의 외심과 내심',
              page: 20,
              hasExercise: false,
              subUnits: <TextbookTocSubUnit>[],
            ),
          ],
        ),
        TextbookTocBigUnit(
          name: '사각형의 성질',
          midUnits: <TextbookTocMidUnit>[
            TextbookTocMidUnit(
              name: '평행사변형',
              page: 36,
              hasExercise: false,
              subUnits: <TextbookTocSubUnit>[],
            ),
          ],
        ),
      ],
      // 본문은 워크북 시작(166쪽) 직전에서 끝난다.
      appendixBoundaryPage: 166,
      notes: '',
    );

    final tree = buildTocAutofillTree(
      toc,
      subUnitRows: false,
      seriesKey: 'gojaengi',
      tocPageOffset: 0,
      lastRawPage: 236,
    );

    expect(tree.length, 2);
    // 대단원 경계를 넘어서도 다음 중단원 시작 직전까지가 본문 범위다.
    expect(tree[0].midUnits[0].startPage, 6);
    expect(tree[0].midUnits[0].endPage, 19);
    expect(tree[0].midUnits[1].startPage, 20);
    expect(tree[0].midUnits[1].endPage, 35);
    // 마지막 본문 중단원은 워크북 시작 직전에서 끊긴다.
    expect(tree[1].midUnits[0].startPage, 36);
    expect(tree[1].midUnits[0].endPage, 165);
    // 문제 단계는 소단원이 아니다.
    expect(tree[0].midUnits[1].subUnits, isEmpty);
    // 대단원마다 끝에 "대단원 TEST" 중단원 행이 하나 선다. 쪽 범위는 목차에
    // 없고 워크북 지면을 훑어야 나오므로 비어 있다.
    expect(tree[0].midUnits.last.name, '대단원 TEST');
    expect(tree[0].midUnits.last.startPage, isNull);
    expect(tree[1].midUnits.last.name, '대단원 TEST');
    // 본문 중단원의 끝 경계 계산에 끼어들지 않는다.
    expect(tree[0].midUnits.length, 3);
    expect(tree[1].midUnits.length, 2);
  });

  test('고쟁이는 Step 머리말로 A/B/C/D 네 단계를 분리한다', () async {
    final mid = TocAutofillMidUnit(name: '삼각형의 외심과 내심')
      ..startPage = 20
      ..endPage = 34;
    final big = TocAutofillBigUnit(name: '삼각형의 성질')..midUnits.add(mid);

    final report = await autofillProblemBookPartRanges(
      <TocAutofillBigUnit>[big],
      series: 'gojaengi',
      classify: (rawPages) async => <TextbookRpmSectionPage>[
        for (final page in rawPages)
          TextbookRpmSectionPage(
            rawPage: page,
            section: page < 25
                ? 'core_type'
                : page < 31
                    ? 'advanced_type'
                    : page < 34
                        ? 'top_type'
                        : 'creative_type',
            // 머리말은 파트 첫 지면에만 인쇄된다. p20 은 머리말 없는 개념 지면.
            headerVisible: page == 21 || page == 25 || page == 31 || page == 34,
          ),
      ],
    );

    expect(report.incompleteMids, isEmpty);
    expect(report.completedMids, 1);
    // 개념 지면(p20)은 첫 파트에 함께 담긴다.
    expect(mid.rpmPartRanges['A']!.startPage, 20);
    expect(mid.rpmPartRanges['A']!.endPage, 24);
    expect(mid.rpmPartRanges['B']!.startPage, 25);
    expect(mid.rpmPartRanges['B']!.endPage, 30);
    expect(mid.rpmPartRanges['C']!.startPage, 31);
    expect(mid.rpmPartRanges['C']!.endPage, 33);
    expect(mid.rpmPartRanges['D']!.startPage, 34);
    expect(mid.rpmPartRanges['D']!.endPage, 34);
  });

  test('창의융합 머리말을 놓치면 미완료로 남기고 범위를 만들지 않는다', () async {
    final mid = TocAutofillMidUnit(name: '삼각형의 외심과 내심')
      ..startPage = 20
      ..endPage = 34;
    final big = TocAutofillBigUnit(name: '삼각형의 성질')..midUnits.add(mid);

    final report = await autofillProblemBookPartRanges(
      <TocAutofillBigUnit>[big],
      series: 'gojaengi',
      classify: (rawPages) async => <TextbookRpmSectionPage>[
        for (final page in rawPages)
          TextbookRpmSectionPage(
            rawPage: page,
            section: page < 25
                ? 'core_type'
                : page < 31
                    ? 'advanced_type'
                    : 'top_type',
            headerVisible: page == 21 || page == 25 || page == 31,
          ),
      ],
    );

    expect(report.completedMids, 0);
    expect(report.incompleteMids.single, contains('D'));
    expect(mid.rpmPartRanges, isEmpty);
  });

  test('고쟁이 카탈로그는 A~F 슬롯을 쓰고 F는 "대단원 TEST" 행만 갖는다', () {
    final entry = textbookSeriesByKey('gojaengi');
    expect(entry, isNotNull);
    expect(entry!.displayName, '고쟁이');
    expect(entry.defaultTextbookType, '문제집');
    expect(
      entry.subPreset.map((s) => s.key).toList(),
      <String>['A', 'B', 'C', 'D', 'E', 'F'],
    );
    // D·E 는 책에 인쇄된 단계 글자가 없어 슬롯 글자를 붙이지 않는다.
    expect(
      entry.subPreset.map((s) => s.displayName).toList(),
      <String>[
        'A STEP1 핵심 유형',
        'B STEP2 심화 유형',
        'C STEP3 최고난도 유형',
        '창의융합 유형',
        '중단원 TEST',
        '대단원 TEST',
      ],
    );
    expect(entry.hasSubUnitRows, isFalse);

    // 본문 중단원은 A~E 만, 대단원 끝 전용 행은 F 만 갖는다. 모든 중단원에 F 를
    // 두면 대단원 TEST 가 없는 중단원까지 미완료로 집계된다.
    expect(
      entry.slotsForMid('삼각형의 외심과 내심').map((s) => s.key).toList(),
      <String>['A', 'B', 'C', 'D', 'E'],
    );
    expect(
      entry.slotsForMid('대단원 TEST').map((s) => s.key).toList(),
      <String>['F'],
    );
    expect(entry.isTrailingMidRow('대단원 TEST'), isTrue);
    expect(entry.isTrailingMidRow('중단원 TEST'), isFalse);

    // 단계 슬롯이 하나뿐인 시리즈는 이 갈림길이 없어야 한다.
    final ssen = textbookSeriesByKey('ssen')!;
    expect(ssen.trailingMidSlotKeys, isEmpty);
    expect(
      ssen.slotsForMid('아무 중단원').map((s) => s.key).toList(),
      <String>['A', 'B', 'C'],
    );
  });

  test('워크북 지면 머리말로 중단원 TEST(E)·대단원 TEST(F) 쪽을 채운다', () async {
    // 실지면 기준: 중단원 TEST 는 소단원마다 네 쪽(166~169, 170~173 …),
    // 대단원 TEST 는 대단원마다 여섯 쪽(206~211)이고 교재 맨 뒤에 몰려 있다.
    final big = TocAutofillBigUnit(name: '삼각형의 성질')
      ..midUnits.addAll(<TocAutofillMidUnit>[
        TocAutofillMidUnit(name: '이등변삼각형과 직각삼각형'),
        TocAutofillMidUnit(name: '삼각형의 외심과 내심'),
      ]);

    final report = await autofillGojaengiWorkbookRanges(
      <TocAutofillBigUnit>[big],
      workbookStartPage: 166,
      // 워크북 뒤로 백지가 두 쪽 붙어 있는 상황까지 함께 본다.
      workbookEndPage: 213,
      classify: (rawPages) async => <TextbookGojaengiWorkbookPage>[
        for (final page in rawPages)
          if (page <= 169)
            TextbookGojaengiWorkbookPage(
              rawPage: page,
              corner: 'mid_unit_test',
              unitNumber: 1,
              unitName: '이등변삼각형과 직각삼각형',
            )
          else if (page <= 173)
            TextbookGojaengiWorkbookPage(
              rawPage: page,
              corner: 'mid_unit_test',
              unitNumber: 2,
              unitName: '삼각형의 외심과 내심',
            )
          else if (page <= 205)
            const TextbookGojaengiWorkbookPage(
              rawPage: 0,
              corner: 'unknown',
              unitNumber: null,
              unitName: '',
            )
          else if (page <= 211)
            TextbookGojaengiWorkbookPage(
              rawPage: page,
              corner: 'big_unit_test',
              unitNumber: 1,
              unitName: '삼각형의 성질',
            )
          else
            TextbookGojaengiWorkbookPage(
              rawPage: page,
              corner: 'unknown',
              unitNumber: null,
              unitName: '',
            ),
      ],
    );

    expect(report.unmatched, isEmpty);
    expect(report.midTestCount, 2);
    expect(report.bigTestCount, 1);
    expect(big.midUnits[0].rpmPartRanges['E']!.startPage, 166);
    expect(big.midUnits[0].rpmPartRanges['E']!.endPage, 169);
    expect(big.midUnits[1].rpmPartRanges['E']!.startPage, 170);
    expect(big.midUnits[1].rpmPartRanges['E']!.endPage, 173);
    // 대단원 TEST 는 본문 중단원이 아니라 전용 행에 담긴다.
    final trailing = big.midUnits.last;
    expect(trailing.name, '대단원 TEST');
    expect(trailing.rpmPartRanges['F']!.startPage, 206);
    // 마지막 머리말(211쪽) 뒤의 백지까지 빨려 들어가면 안 된다.
    expect(trailing.rpmPartRanges['F']!.endPage, 211);
    expect(trailing.startPage, 206);
    expect(trailing.endPage, 211);
    // 본문 중단원에는 F 범위가 생기지 않는다.
    expect(big.midUnits[1].rpmPartRanges.containsKey('F'), isFalse);
  });

  test('워크북 머리말 이름이 어긋나면 번호로 되짚는다', () async {
    final big = TocAutofillBigUnit(name: '삼각형의 성질')
      ..midUnits.addAll(<TocAutofillMidUnit>[
        TocAutofillMidUnit(name: '이등변삼각형과 직각삼각형'),
        TocAutofillMidUnit(name: '삼각형의 외심과 내심'),
      ]);

    final report = await autofillGojaengiWorkbookRanges(
      <TocAutofillBigUnit>[big],
      workbookStartPage: 170,
      workbookEndPage: 171,
      classify: (rawPages) async => <TextbookGojaengiWorkbookPage>[
        for (final page in rawPages)
          TextbookGojaengiWorkbookPage(
            rawPage: page,
            corner: 'mid_unit_test',
            unitNumber: 2,
            // 판독이 이름을 흘렸어도 소단원 번호는 책 전체에서 이어진다.
            unitName: '삼각형의 외심과 내심(오독)',
          ),
      ],
    );

    expect(report.unmatched, isEmpty);
    expect(big.midUnits[1].rpmPartRanges['E']!.startPage, 170);
    expect(big.midUnits[1].rpmPartRanges['E']!.endPage, 171);
  });

  test('본문 단계 자동분류는 "대단원 TEST" 행을 미완료로 세지 않는다', () async {
    final mid = TocAutofillMidUnit(name: '삼각형의 외심과 내심')
      ..startPage = 20
      ..endPage = 34;
    final big = TocAutofillBigUnit(name: '삼각형의 성질')
      ..midUnits.add(mid)
      // 쪽이 비어 있는 전용 행. 본문 단계가 없으니 건너뛰어야 한다.
      ..midUnits.add(TocAutofillMidUnit(name: '대단원 TEST'));

    final report = await autofillProblemBookPartRanges(
      <TocAutofillBigUnit>[big],
      series: 'gojaengi',
      classify: (rawPages) async => <TextbookRpmSectionPage>[
        for (final page in rawPages)
          TextbookRpmSectionPage(
            rawPage: page,
            section: page < 25
                ? 'core_type'
                : page < 31
                    ? 'advanced_type'
                    : page < 34
                        ? 'top_type'
                        : 'creative_type',
            headerVisible: page == 21 || page == 25 || page == 31 || page == 34,
          ),
      ],
    );

    expect(report.incompleteMids, isEmpty);
    expect(report.completedMids, 1);
  });
}
