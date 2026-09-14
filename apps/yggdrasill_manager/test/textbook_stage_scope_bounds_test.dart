import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_authoring_stage_dialog.dart';

// 고쟁이 2-2 세 번째 중단원 실사례. 본교재 해설(A~D) 은 앞쪽 지면에 있고
// 중단원 TEST(E) 해설은 교재 맨 뒤 워크북 지면에 몰려 있다. 훑기 범위는
// 스코프 합집합이라 11쪽부터 열리는데, 워크북 "05" 와 본교재 "005" 는 번호키가
// 같아서 E 문항이 앞쪽 본교재 풀이를 집어 오며 크롭이 통째로 어긋났다.
const bounds = <String, TextbookStageScopeBound>{
  '2:2:A:0': (start: 11, end: 20),
  '2:2:B:0': (start: 20, end: 31),
  '2:2:E:0': (start: 160, end: null),
};

const scopeKeyByPosition = <int, String>{
  0: '2:2:A:0',
  1: '2:2:B:0',
  2: '2:2:E:0',
};

List<int> orderOn(int page, {List<int> order = const [0, 1, 2]}) =>
    textbookStageOrderForPage(
      order: order,
      scopeKeyOf: (position) => scopeKeyByPosition[position] ?? '',
      bounds: bounds,
      page: page,
    );

void main() {
  test('앞쪽 본교재 지면에서는 중단원 TEST 문항을 묻지 않는다', () {
    expect(orderOn(11), [0]);
    expect(orderOn(25), [1]);
  });

  test('중단원 TEST 지면에 닿으면 그 문항만 묻는다', () {
    expect(orderOn(165), [2]);
  });

  test('뒤로 열린 소단원은 PDF 끝까지 살아 있다', () {
    expect(orderOn(190), [2]);
  });

  test('펼침면 앞뒤로 한 쪽은 넘겨 준다', () {
    // 소단원 머리말 쪽 직전에 첫 문항 풀이가 걸치는 경우.
    expect(orderOn(159), contains(2));
    // 마지막 문항 풀이가 다음 쪽 머리로 넘어가는 경우.
    expect(orderOn(21), contains(0));
    expect(orderOn(22), isNot(contains(0)));
  });

  test('고쟁이 워크북은 입력한 시작 쪽 이전을 절대 묻지 않는다', () {
    final before = textbookStageOrderForPage(
      order: const [2],
      scopeKeyOf: (position) => scopeKeyByPosition[position] ?? '',
      bounds: bounds,
      page: 159,
      leadingPageAllowance: 0,
    );
    final atStart = textbookStageOrderForPage(
      order: const [2],
      scopeKeyOf: (position) => scopeKeyByPosition[position] ?? '',
      bounds: bounds,
      page: 160,
      leadingPageAllowance: 0,
    );
    expect(before, isEmpty);
    expect(atStart, [2]);
  });

  test('스코프를 못 짚는 문항은 전 구간에서 찾는다', () {
    final out = textbookStageOrderForPage(
      order: const [0, 9],
      scopeKeyOf: (position) => scopeKeyByPosition[position] ?? '',
      bounds: bounds,
      page: 170,
    );
    expect(out, [9]);
  });

  test('경계가 하나도 없으면 예전처럼 전부 묻는다', () {
    final out = textbookStageOrderForPage(
      order: const [0, 1, 2],
      scopeKeyOf: (position) => scopeKeyByPosition[position] ?? '',
      bounds: const {},
      page: 11,
    );
    expect(out, [0, 1, 2]);
  });

  test('스코프 키는 소단원 행 순번까지 갈라 준다', () {
    const scope = TextbookAuthoringStageScope(
      bigOrder: 2,
      midOrder: 2,
      subKey: 'E',
      unitRowIndex: 3,
    );
    expect(textbookStageScopeKey(scope), '2:2:E:3');
  });

  test('고쟁이는 본교재와 두 TEST 해설 경계를 서로 섞지 않는다', () {
    expect(textbookStagePageFamily('gojaengi', 'A'), 'body');
    expect(textbookStagePageFamily('gojaengi', 'D'), 'body');
    expect(textbookStagePageFamily('gojaengi', 'E'), 'mid_test');
    expect(textbookStagePageFamily('gojaengi', 'F'), 'big_test');
    expect(textbookStagePageFamily('ssen', 'E'), isEmpty);
  });
}
