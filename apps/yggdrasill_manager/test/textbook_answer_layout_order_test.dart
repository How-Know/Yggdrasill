import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_answer_service.dart';

// 수력충전 빠른 정답은 소단원 머리 아래로 정답이 이어지고, 왼쪽 단이 끝나면
// 오른쪽 단으로 넘어간다. 앱은 머리를 만날 때마다 "지금 소단원"을 바꾸므로
// 정답이 자기 머리보다 먼저 오면 버려진다. 1-2 답지 10쪽에서 모델이 오른쪽
// 단을 먼저 적어 와 "05 도수분포표" 06~45번 40개가 통째로 비었다.

TextbookVlmAnswerLayoutEntry header(String title, List<int> bbox) {
  return TextbookVlmAnswerLayoutEntry(
    isHeader: true,
    title: title,
    pageStart: 180,
    pageEnd: 186,
    bbox: bbox,
  );
}

TextbookVlmAnswerLayoutEntry answer(String number, List<int> bbox) {
  return TextbookVlmAnswerLayoutEntry(
    isHeader: false,
    answer: TextbookVlmAnswerItem(
      problemNumber: number,
      kind: 'subjective',
      answerText: '답',
      answerLatex2d: '',
    ),
    bbox: bbox,
  );
}

List<String> namesOf(List<TextbookVlmAnswerLayoutEntry> entries) {
  return <String>[
    for (final entry in entries)
      entry.isHeader ? '머리:${entry.title}' : entry.answer!.problemNumber,
  ];
}

void main() {
  test('오른쪽 단을 먼저 적어 와도 읽기 순서로 다시 세운다', () {
    final reordered = textbookAnswerLayoutReadingOrder(
      <TextbookVlmAnswerLayoutEntry>[
        answer('06', <int>[67, 519, 78, 660]),
        answer('07', <int>[86, 519, 98, 676]),
        header('04 줄기와 잎 그림', <int>[104, 86, 122, 471]),
        answer('01', <int>[138, 86, 216, 365]),
        header('05 도수분포표', <int>[466, 86, 484, 471]),
        answer('05', <int>[817, 86, 924, 266]),
      ],
    );
    expect(namesOf(reordered), <String>[
      '머리:04 줄기와 잎 그림',
      '01',
      '머리:05 도수분포표',
      '05',
      '06',
      '07',
    ]);
  });

  test('이미 읽기 순서면 그대로 둔다', () {
    final entries = <TextbookVlmAnswerLayoutEntry>[
      header('05 도수분포표', <int>[466, 86, 484, 471]),
      answer('01', <int>[503, 86, 514, 266]),
      answer('02', <int>[522, 86, 604, 266]),
      answer('06', <int>[67, 519, 78, 660]),
    ];
    expect(
      namesOf(textbookAnswerLayoutReadingOrder(entries)),
      namesOf(entries),
    );
  });

  test('단을 넘어 이어진 정답은 모델이 적어 준 자리에 머문다', () {
    // 2-1 답지 10쪽. "12 …농도" 09번 정답이 왼쪽 단 맨 아래에서 시작해
    // 오른쪽 단 맨 위로 이어져, 모델이 두 조각을 아우른 지면만 한 상자를 준다.
    final reordered = textbookAnswerLayoutReadingOrder(
      <TextbookVlmAnswerLayoutEntry>[
        header('11 연립방정식의 활용 - 거리', <int>[68, 101, 84, 483]),
        answer('24', <int>[601, 93, 613, 273]),
        header('12 연립방정식의 활용 - 농도', <int>[649, 101, 665, 484]),
        answer('08', <int>[846, 93, 858, 306]),
        answer('09', <int>[66, 93, 921, 783]),
        answer('10', <int>[86, 532, 98, 642]),
        header('단원 마무리 평가 [10~12]', <int>[144, 542, 160, 913]),
        answer('01', <int>[172, 542, 184, 606]),
      ],
    );
    expect(namesOf(reordered), <String>[
      '머리:11 연립방정식의 활용 - 거리',
      '24',
      '머리:12 연립방정식의 활용 - 농도',
      '08',
      '09',
      '10',
      '머리:단원 마무리 평가 [10~12]',
      '01',
    ]);
  });

  test('좌표가 없는 요소가 있으면 모델이 준 순서를 건드리지 않는다', () {
    final entries = <TextbookVlmAnswerLayoutEntry>[
      answer('06', <int>[67, 519, 78, 660]),
      header('05 도수분포표', <int>[466, 86, 484, 471]),
      const TextbookVlmAnswerLayoutEntry(isHeader: true, title: '좌표 없음'),
    ];
    expect(
      namesOf(textbookAnswerLayoutReadingOrder(entries)),
      namesOf(entries),
    );
  });
}
