import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_toc_autofill.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_test_service.dart';

void main() {
  test('RPM 목차 중단원 페이지와 부록 경계로 본문 범위를 만든다', () {
    const toc = TextbookTocParseResult(
      bigUnits: <TextbookTocBigUnit>[
        TextbookTocBigUnit(
          name: 'I. 소인수분해',
          midUnits: <TextbookTocMidUnit>[
            TextbookTocMidUnit(
              name: '01 소인수분해',
              page: 8,
              hasExercise: false,
              subUnits: <TextbookTocSubUnit>[],
            ),
            TextbookTocMidUnit(
              name: '02 최대공약수와 최소공배수',
              page: 18,
              hasExercise: false,
              subUnits: <TextbookTocSubUnit>[],
            ),
          ],
        ),
      ],
      appendixBoundaryPage: 34,
      notes: '',
    );

    final tree = buildTocAutofillTree(
      toc,
      subUnitRows: false,
      tocPageOffset: 2,
    );

    expect(tree.single.name, '소인수분해');
    expect(tree.single.midUnits[0].name, '소인수분해');
    expect(tree.single.midUnits[0].startPage, 10);
    expect(tree.single.midUnits[0].endPage, 19);
    expect(tree.single.midUnits[1].startPage, 20);
    expect(tree.single.midUnits[1].endPage, 35);
  });

  test('RPM 헤더 페이지로 A/B/C 범위를 분리한다', () async {
    final mid = TocAutofillMidUnit(name: '소인수분해')
      ..startPage = 10
      ..endPage = 19;
    final big = TocAutofillBigUnit(name: '소인수분해')..midUnits.add(mid);

    final report = await autofillProblemBookPartRanges(
      <TocAutofillBigUnit>[big],
      classify: (rawPages) async => <TextbookRpmSectionPage>[
        for (final page in rawPages)
          TextbookRpmSectionPage(
            rawPage: page,
            section: page < 15
                ? 'basic_drill'
                : (page < 18 ? 'type_practice' : 'mastery'),
            typePracticeHeaderVisible: page == 15,
            masteryHeaderVisible: page == 18,
          ),
      ],
    );

    expect(report.completedMids, 1);
    expect(report.incompleteMids, isEmpty);
    expect(mid.rpmPartRanges['A']!.startPage, 10);
    expect(mid.rpmPartRanges['A']!.endPage, 14);
    expect(mid.rpmPartRanges['B']!.startPage, 15);
    expect(mid.rpmPartRanges['B']!.endPage, 17);
    expect(mid.rpmPartRanges['C']!.startPage, 18);
    expect(mid.rpmPartRanges['C']!.endPage, 19);
  });

  test('쎈 마지막 중단원은 본문 PDF 끝을 종료 경계로 사용한다', () {
    const toc = TextbookTocParseResult(
      bigUnits: <TextbookTocBigUnit>[
        TextbookTocBigUnit(
          name: 'IV 통계',
          midUnits: <TextbookTocMidUnit>[
            TextbookTocMidUnit(
              name: '10 도수분포표',
              page: 184,
              hasExercise: false,
              subUnits: <TextbookTocSubUnit>[],
            ),
            TextbookTocMidUnit(
              name: '11 상대도수',
              page: 204,
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
      tocPageOffset: 2,
      lastRawPage: 228,
    );

    expect(tree.single.name, '통계');
    expect(tree.single.midUnits[0].startPage, 186);
    expect(tree.single.midUnits[0].endPage, 205);
    expect(tree.single.midUnits[1].startPage, 206);
    expect(tree.single.midUnits[1].endPage, 228);
  });
}
