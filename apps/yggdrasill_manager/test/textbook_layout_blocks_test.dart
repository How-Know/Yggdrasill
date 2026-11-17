import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_stage_batch_service.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_answer_service.dart';

// 수력충전 1-2 평행선: 답지 2쪽에 단원 마무리(p.36~38)·14 동위각(p.39)·15 엇각(p.40)·
// 16 평행선의 성질(p.41~43)이 함께 실리고 번호는 블록마다 01부터 다시 시작한다.
// 기대 번호로 물으면 엇각 01~10 자리에 다른 블록의 01~10 이 들어왔다.
void main() {
  List<TextbookExpectedAnswer> unit(int page, int count, {int from = 1, String corner = ''}) => [
        for (var n = from; n < from + count; n += 1)
          TextbookExpectedAnswer(number: n.toString().padLeft(2, '0'), corner: corner, bodyPage: page),
      ];

  test('범위 밖 소단원 머리는 블록을 정하지 않는다', () {
    final blocks = TextbookLayoutBlocks.of(unit(40, 10));
    expect(blocks.blockForHeader('단원 마무리 평가 [09~13]', 36, 38), -1);
    expect(blocks.blockForHeader('14 동위각', 39, 39), -1);
    expect(blocks.blockForHeader('15 엇각', 40, 40), 0);
    expect(blocks.blockForHeader('16 평행선의 성질', 41, 43), -1);
  });

  test('쪽 범위 머리 하나가 여러 본문 쪽에 걸친 블록 전체를 가리킨다', () {
    final blocks = TextbookLayoutBlocks.of([...unit(41, 8), ...unit(42, 12, from: 9), ...unit(43, 12, from: 21)]);
    final block = blocks.blockForHeader('16 평행선의 성질', 41, 43);
    expect(block, 0);
    final pending = <int>{for (var i = 0; i < 32; i += 1) i};
    expect(blocks.positionsFor(block, '17', pending), [16]);
    expect(blocks.positionsFor(block, '32', pending), [31]);
  });

  test('묶음 번호는 범위의 문항 모두를, 이미 채운 문항은 빼고 돌려준다', () {
    final blocks = TextbookLayoutBlocks.of(unit(47, 8));
    expect(blocks.positionsFor(0, '05~07', {4, 6}), [4, 6]);
    expect(blocks.positionsFor(0, '04', {4, 6}), isEmpty);
  });

  test('번호가 되돌아가거나 코너가 바뀌면 블록을 끊는다', () {
    final blocks = TextbookLayoutBlocks.of([
      ...unit(46, 7),
      ...unit(47, 8),
      ...unit(49, 3, corner: '단원 마무리 평가'),
    ]);
    expect(blocks.blockForHeader('18 평행선과 종이접기', 46, 46), 0);
    expect(blocks.blockForHeader('19 평행선이 되기 위한 조건', 47, 48), 1);
    expect(blocks.blockForHeader('단원 마무리 평가 [14~19]', 49, 51), 2);
    expect(blocks.positionsFor(1, '04', {for (var i = 0; i < 18; i += 1) i}), [10]);
  });

  // 크롭 목록은 쪽·번호 내림차순으로 온다(엇각 10→01, 조건 p.48 17→09 다음 p.47 08→01).
  test('입력이 번호 내림차순이어도 한 소단원은 블록 하나다', () {
    final expected = [
      ...unit(48, 9, from: 9).reversed,
      ...unit(47, 8).reversed,
    ];
    final blocks = TextbookLayoutBlocks.of(expected);
    final block = blocks.blockForHeader('19 평행선이 되기 위한 조건', 47, 48);
    expect(block, 0);
    final pending = <int>{for (var i = 0; i < expected.length; i += 1) i};
    final filled = <int>[
      for (var n = 1; n <= 17; n += 1) ...blocks.positionsFor(block, n.toString().padLeft(2, '0'), pending),
    ];
    expect(filled.toSet(), pending);
    expect(expected[blocks.positionsFor(block, '04', pending).single].number, '04');
  });
}
