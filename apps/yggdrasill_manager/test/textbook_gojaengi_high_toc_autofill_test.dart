import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_toc_autofill.dart';
import 'package:yggdrasill_manager/services/textbook_series_catalog.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_test_service.dart';

/// 고쟁이 고등 공통수학1 실지면 기준.
///   01 다항식의 연산 = p7~25
///   p7 개념 · p8 STEP1 · p14 STEP2 · p21 스키마 · p22 STEP3
///   마지막 중단원 "행렬의 뜻과 연산" = p203~, 빠른 정답 = p233~238
void main() {
  test('고쟁이 고등 카탈로그는 A~C 세 슬롯만 쓴다', () {
    final entry = textbookSeriesByKey('gojaengi_high');
    expect(entry, isNotNull);
    expect(entry!.displayName, '고쟁이 고등');
    expect(entry.defaultTextbookType, '문제집');
    expect(entry.subPreset.map((s) => s.key).toList(), <String>['A', 'B', 'C']);
    expect(entry.trailingMidRowName, isEmpty);
    expect(isGojaengiSeries('gojaengi_high'), isTrue);
    expect(isGojaengiSeries('gojaengi'), isTrue);
    expect(isGojaengiSeries('ssen'), isFalse);
  });

  test('고쟁이 고등 목차는 대단원 TEST 행을 세우지 않는다', () {
    const toc = TextbookTocParseResult(
      bigUnits: <TextbookTocBigUnit>[
        TextbookTocBigUnit(
          name: '다항식',
          midUnits: <TextbookTocMidUnit>[
            TextbookTocMidUnit(
              name: '다항식의 연산',
              page: 7,
              hasExercise: false,
              subUnits: <TextbookTocSubUnit>[],
            ),
            TextbookTocMidUnit(
              name: '항등식과 나머지정리',
              page: 26,
              hasExercise: false,
              subUnits: <TextbookTocSubUnit>[],
            ),
          ],
        ),
      ],
      notes: '',
    );

    final tree = buildTocAutofillTree(
      toc,
      subUnitRows: false,
      seriesKey: 'gojaengi_high',
      tocPageOffset: 0,
      lastRawPage: 238,
    );

    expect(tree.single.midUnits.map((m) => m.name).toList(), <String>[
      '다항식의 연산',
      '항등식과 나머지정리',
    ]);
    expect(tree.single.midUnits[0].endPage, 25);
    expect(tree.single.midUnits[1].endPage, 238);
  });

  test('고쟁이 고등은 STEP 머리말로 A/B/C 세 단계를 분리한다', () async {
    final mid = TocAutofillMidUnit(name: '다항식의 연산')
      ..startPage = 7
      ..endPage = 25;
    final big = TocAutofillBigUnit(name: '다항식')..midUnits.add(mid);

    final report = await autofillProblemBookPartRanges(
      <TocAutofillBigUnit>[big],
      series: 'gojaengi_high',
      classify: (rawPages) async => <TextbookRpmSectionPage>[
        for (final page in rawPages)
          TextbookRpmSectionPage(
            rawPage: page,
            section: page < 14
                ? 'core_type'
                : page < 22
                    ? 'advanced_type'
                    : 'top_type',
            headerVisible: page.isEven && page != 26,
          ),
      ],
    );

    expect(report.incompleteMids, isEmpty);
    expect(mid.rpmPartRanges['A']!.startPage, 7);
    expect(mid.rpmPartRanges['A']!.endPage, 13);
    expect(mid.rpmPartRanges['B']!.startPage, 14);
    expect(mid.rpmPartRanges['B']!.endPage, 21);
    expect(mid.rpmPartRanges['C']!.startPage, 22);
    expect(mid.rpmPartRanges['C']!.endPage, 25);
    expect(mid.rpmPartRanges.containsKey('D'), isFalse);
  });

  test('마지막 중단원은 책 끝 빠른 정답 지면 앞에서 끊긴다', () async {
    final mid = TocAutofillMidUnit(name: '행렬의 뜻과 연산')
      ..startPage = 203
      ..endPage = 238;
    final big = TocAutofillBigUnit(name: '행렬')..midUnits.add(mid);

    final report = await autofillProblemBookPartRanges(
      <TocAutofillBigUnit>[big],
      series: 'gojaengi_high',
      classify: (rawPages) async => <TextbookRpmSectionPage>[
        for (final page in rawPages)
          TextbookRpmSectionPage(
            rawPage: page,
            section: page >= 233
                ? kProblemBookAnswerKeySection
                : page < 210
                    ? 'core_type'
                    : page < 224
                        ? 'advanced_type'
                        : 'top_type',
            headerVisible: page == 204 || page == 210 || page == 224,
          ),
      ],
    );

    expect(report.incompleteMids, isEmpty);
    expect(mid.endPage, 232);
    expect(mid.rpmPartRanges['C']!.startPage, 224);
    expect(mid.rpmPartRanges['C']!.endPage, 232);
  });
}
