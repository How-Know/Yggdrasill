import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_toc_autofill.dart';
import 'package:yggdrasill_manager/services/textbook_series_catalog.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_test_service.dart';

/// 개념+유형 목차 한 대단원 분량. 중단원마다 번호 붙은 소단원 뒤에
/// "단원 다지기 / 서술형 완성하기", "개념 리뷰 / 마인드맵" 두 줄이 이어진다.
const _toc = TextbookTocParseResult(
  bigUnits: <TextbookTocBigUnit>[
    TextbookTocBigUnit(
      name: 'I 수와 연산',
      midUnits: <TextbookTocMidUnit>[
        TextbookTocMidUnit(
          name: '1 소인수분해',
          hasExercise: false,
          subUnits: <TextbookTocSubUnit>[
            TextbookTocSubUnit(name: '01 소인수분해', page: 8),
            TextbookTocSubUnit(name: '02 최대공약수와 최소공배수', page: 14),
            TextbookTocSubUnit(
              name: '단원 다지기 / 서술형 완성하기',
              page: 21,
              isExercise: true,
            ),
            TextbookTocSubUnit(
              name: '개념 리뷰 / 마인드맵',
              page: 26,
              isExercise: true,
            ),
          ],
        ),
        TextbookTocMidUnit(
          name: '2 정수와 유리수',
          hasExercise: false,
          subUnits: <TextbookTocSubUnit>[
            TextbookTocSubUnit(name: '01 정수와 유리수', page: 30),
            TextbookTocSubUnit(name: '02 정수와 유리수의 덧셈과 뺄셈', page: 40),
          ],
        ),
      ],
    ),
  ],
  appendixBoundaryPage: null,
  notes: '',
);

void main() {
  test('개념+유형 목차의 마무리 두 줄을 단원 다지기 한 행으로 합친다', () {
    final tree = buildTocAutofillTree(
      _toc,
      subUnitRows: true,
      seriesKey: 'gaeyu',
    );

    final mid = tree.single.midUnits.first;
    expect(mid.name, '소인수분해');
    expect(
      mid.subUnits.map((s) => s.name).toList(),
      <String>['소인수분해', '최대공약수와 최소공배수', '단원 다지기'],
    );

    final unitEnd = mid.subUnits.last;
    expect(unitEnd.isExercise, isTrue);
    // 시작은 "단원 다지기" 줄의 21쪽, 끝은 다음 중단원 첫 소단원 직전인 29쪽.
    expect(unitEnd.startPage, 21);
    expect(unitEnd.endPage, 29);
  });

  test('개념+유형 소단원 페이지는 다음 항목 시작 직전까지 채운다', () {
    final tree = buildTocAutofillTree(
      _toc,
      subUnitRows: true,
      seriesKey: 'gaeyu',
      tocPageOffset: 2,
    );

    final subs = tree.single.midUnits.first.subUnits;
    expect(subs[0].startPage, 10);
    expect(subs[0].endPage, 15);
    expect(subs[1].startPage, 16);
    expect(subs[1].endPage, 22);
    expect(subs[2].startPage, 23);
    expect(subs[2].endPage, 31);
  });

  test('개념+유형 문제 카테고리 라벨은 단원으로 올라오지 않는다', () {
    const noisy = TextbookTocParseResult(
      bigUnits: <TextbookTocBigUnit>[
        TextbookTocBigUnit(
          name: 'I 수와 연산',
          midUnits: <TextbookTocMidUnit>[
            TextbookTocMidUnit(
              name: '1 소인수분해',
              hasExercise: false,
              subUnits: <TextbookTocSubUnit>[
                TextbookTocSubUnit(name: '01 소인수분해', page: 8),
                TextbookTocSubUnit(name: '쏙쏙 개념 익히기', page: 12),
                TextbookTocSubUnit(name: '탄탄 단원 다지기', page: 21),
              ],
            ),
          ],
        ),
      ],
      appendixBoundaryPage: null,
      notes: '',
    );

    final tree = buildTocAutofillTree(
      noisy,
      subUnitRows: true,
      seriesKey: 'gaeyu',
    );

    expect(
      tree.single.midUnits.first.subUnits.map((s) => s.name).toList(),
      <String>['소인수분해'],
    );
  });

  test('개념원리 연습문제 행은 합쳐지지 않고 그대로 남는다', () {
    const wonriToc = TextbookTocParseResult(
      bigUnits: <TextbookTocBigUnit>[
        TextbookTocBigUnit(
          name: 'I. 다항식',
          midUnits: <TextbookTocMidUnit>[
            TextbookTocMidUnit(
              name: '1. 다항식의 연산',
              hasExercise: false,
              subUnits: <TextbookTocSubUnit>[
                TextbookTocSubUnit(name: '01 다항식의 덧셈과 뺄셈', page: 10),
                TextbookTocSubUnit(name: '연습문제', page: 18, isExercise: true),
                TextbookTocSubUnit(name: '02 다항식의 곱셈', page: 20),
                TextbookTocSubUnit(name: '연습문제', page: 28, isExercise: true),
              ],
            ),
          ],
        ),
      ],
      appendixBoundaryPage: null,
      notes: '',
    );

    final tree = buildTocAutofillTree(
      wonriToc,
      subUnitRows: true,
      seriesKey: 'wonri',
    );

    expect(
      tree.single.midUnits.first.subUnits.map((s) => s.name).toList(),
      <String>['다항식의 덧셈과 뺄셈', '연습문제', '다항식의 곱셈', '연습문제'],
    );
  });

  test('소단원 번호가 O1 로 읽혀도 이름만 남는다', () {
    expect(stripTocUnitNumbering('O1 순서쌍과 좌표'), '순서쌍과 좌표');
    expect(stripTocUnitNumbering('O2 그래프와 그 해석'), '그래프와 그 해석');
    // 영문 단원명의 첫 글자를 번호로 오인하지 않는다.
    expect(stripTocUnitNumbering('Order of Operations'), 'Order of Operations');
  });

  test('개념+유형 시리즈는 소단원 행을 쓰고 마무리 슬롯이 D·E 다', () {
    final entry = textbookSeriesByKey('gaeyu');
    expect(entry, isNotNull);
    expect(entry!.hasSubUnitRows, isTrue);
    expect(entry.unitEndRowName, '단원 다지기');
    expect(entry.unitEndSlotKeys, <String>{'D', 'E'});
    // 한 번 더 연습(F)은 소단원마다 있는 코너가 아니라 payload 슬롯이 아니다.
    expect(entry.subPreset.map((p) => p.key).toList(),
        <String>['A', 'B', 'C', 'D', 'E']);
    expect(entry.supportsProblemExtraction, isTrue);
  });
}
