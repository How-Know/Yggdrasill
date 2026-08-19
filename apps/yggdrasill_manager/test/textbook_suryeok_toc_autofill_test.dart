import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_toc_autofill.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_test_service.dart';

/// 수력충전 목차 끝부분. 대단원마다 소단원 + "단원 마무리 평가" 가 이어지고,
/// 목차 맨 끝에 대단원별 "실력 향상 테스트" 묶음이 따로 인쇄된다.
const _toc = TextbookTocParseResult(
  bigUnits: <TextbookTocBigUnit>[
    TextbookTocBigUnit(
      name: 'Ⅲ 통계',
      midUnits: <TextbookTocMidUnit>[
        TextbookTocMidUnit(
          name: '1. 산포도',
          hasExercise: false,
          subUnits: <TextbookTocSubUnit>[
            TextbookTocSubUnit(name: '01 산포도와 편차', page: 156),
            TextbookTocSubUnit(name: '02 편차를 이용하여 변량 구하기', page: 159),
            TextbookTocSubUnit(
              name: '단원 마무리 평가',
              page: 170,
              isExercise: true,
            ),
          ],
        ),
      ],
    ),
    TextbookTocBigUnit(
      name: '학교 시험 대비 실력 향상 테스트',
      midUnits: <TextbookTocMidUnit>[
        TextbookTocMidUnit(
          name: 'Ⅰ단원 실력 향상 테스트',
          page: 200,
          hasExercise: false,
          subUnits: <TextbookTocSubUnit>[
            TextbookTocSubUnit(
              name: '실력 향상 테스트',
              page: 200,
              isExercise: true,
            ),
          ],
        ),
        // 모델이 소단원 줄을 생략하고 중단원 줄만 담아 보내는 경우.
        TextbookTocMidUnit(
          name: 'Ⅱ단원 실력 향상 테스트',
          page: 204,
          hasExercise: false,
          subUnits: <TextbookTocSubUnit>[],
        ),
      ],
    ),
  ],
  appendixBoundaryPage: 212,
  notes: '',
);

void main() {
  test('수력충전 실력 향상 테스트는 대단원별로 이름이 구분된 채 남는다', () {
    final tree = buildTocAutofillTree(
      _toc,
      subUnitRows: true,
      seriesKey: 'suryeok',
    );

    final skill = tree.last;
    expect(skill.name, '학교 시험 대비 실력 향상 테스트');
    expect(
      skill.midUnits.map((m) => m.name).toList(),
      <String>['Ⅰ단원 실력 향상 테스트', 'Ⅱ단원 실력 향상 테스트'],
    );
  });

  test('실력 향상 테스트 중단원은 소단원 줄이 없어도 추출 행 하나를 갖는다', () {
    final tree = buildTocAutofillTree(
      _toc,
      subUnitRows: true,
      seriesKey: 'suryeok',
      tocPageOffset: 2,
    );

    for (final mid in tree.last.midUnits) {
      final row = mid.subUnits.single;
      // 마무리 지면이라 단원 마무리 평가와 같은 슬롯을 타야 하지만,
      // 이름까지 "단원 마무리 평가" 로 덮이면 안 된다.
      expect(row.name, '실력 향상 테스트');
      expect(row.isExercise, isTrue);
    }
    expect(tree.last.midUnits.first.subUnits.single.startPage, 202);
    expect(tree.last.midUnits.last.subUnits.single.startPage, 206);
  });

  test('일반 중단원의 마무리 행은 그대로 단원 마무리 평가로 정규화된다', () {
    final tree = buildTocAutofillTree(
      _toc,
      subUnitRows: true,
      seriesKey: 'suryeok',
    );

    final mid = tree.first.midUnits.single;
    expect(mid.name, '산포도');
    expect(
      mid.subUnits.map((s) => s.name).toList(),
      <String>['산포도와 편차', '편차를 이용하여 변량 구하기', '단원 마무리 평가'],
    );
  });

  test('로마숫자 대단원 표기는 여전히 이름에서 떨어진다', () {
    expect(stripTocUnitNumbering('Ⅲ 통계'), '통계');
    expect(stripTocUnitNumbering('Ⅰ. 다항식'), '다항식');
    expect(stripTocUnitNumbering('Ⅰ단원 실력 향상 테스트'), 'Ⅰ단원 실력 향상 테스트');
  });
}
