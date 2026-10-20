import 'package:flutter/material.dart';

import '../../../think/think_style.dart';

/// 개념 유형. 순서는 "수학 순서"(뜻 → 나타내는 법 → 헷갈리는 점 → 늘 성립하는 사실 → 그 사실로 구하는 법).
enum MockConceptType { definition, notation, caution, property, method, none }

extension MockConceptTypeX on MockConceptType {
  String get label => switch (this) {
        MockConceptType.definition => '정의',
        MockConceptType.notation => '표현',
        MockConceptType.caution => '주의',
        MockConceptType.property => '성질',
        MockConceptType.method => '방법',
        MockConceptType.none => '유형 없음',
      };

  String get glyph => switch (this) {
        MockConceptType.definition => '정',
        MockConceptType.notation => '표',
        MockConceptType.caution => '주',
        MockConceptType.property => '성',
        MockConceptType.method => '방',
        MockConceptType.none => '?',
      };

  Color get color => switch (this) {
        MockConceptType.definition => const Color(0xFFDE6A73),
        MockConceptType.notation => const Color(0xFFB39DDB),
        MockConceptType.caution => const Color(0xFFEAB968),
        MockConceptType.property => const Color(0xFF7AA9E6),
        MockConceptType.method => const Color(0xFF7CC67C),
        MockConceptType.none => kThinkSub,
      };

  String get description => switch (this) {
        MockConceptType.definition => '용어나 대상이 무엇인지 정하는 것',
        MockConceptType.notation => '기호·표기법·나타내는 방식',
        MockConceptType.caution => '헷갈리기 쉬운 예외·조건',
        MockConceptType.property => '대상이 늘 만족하는 사실·법칙·정리',
        MockConceptType.method => '계산하거나 구하는 절차',
        MockConceptType.none => '유형을 붙이기 전에 만든 개념(기존 구분만 있음)',
      };

  int get rank => index;
}

class MockConcept {
  const MockConcept(this.id, this.name, this.type, {this.anchor, this.version});

  final String id;
  final String name;
  final MockConceptType type;

  /// 주제 묶음에서 붙는 정의 이름. 실제로는 AI 제안 + 승인으로 정해야 하는 값이다.
  final String? anchor;
  final String? version;
}

class MockFolder {
  const MockFolder(this.id, this.name, {this.area = false, this.children = const [], this.concepts = const []});

  final String id;
  final String name;
  final bool area;
  final List<MockFolder> children;

  /// 교재 흐름(저장된 순서).
  final List<MockConcept> concepts;

  int get total => concepts.length + children.fold(0, (s, c) => s + c.total);

  Map<MockConceptType, int> get typeCounts {
    final out = <MockConceptType, int>{};
    void visit(MockFolder f) {
      for (final c in f.concepts) {
        out[c.type] = (out[c.type] ?? 0) + 1;
      }
      f.children.forEach(visit);
    }

    visit(this);
    return out;
  }
}

const _d = MockConceptType.definition;
const _n = MockConceptType.notation;
const _c = MockConceptType.caution;
const _p = MockConceptType.property;
const _m = MockConceptType.method;

/// 2026-10-18 운영 라이브러리(개념 43개)와 같은 폴더·이름·유형·저장 순서. "최대공약수 · 기본-2"만 상태 보기용으로 더했다.
const List<MockFolder> kMockLibrary = [
  MockFolder('algebra', '대수', area: true, children: [
    MockFolder('number', '정수론', children: [
      MockFolder('prime', '소수와 합성수', concepts: [
        MockConcept('p1', '소수', _d),
        MockConcept('p2', '합성수', _d),
        MockConcept('p3', '소수의 약수의 개수', _p, anchor: '소수'),
        MockConcept('p4', '합성수의 약수의 개수', _p, anchor: '합성수'),
        MockConcept('p5', '1은 소수도 합성수도 아니다', _c, anchor: '소수'),
        MockConcept('p6', '유일하게 짝수인 소수', _p, anchor: '소수'),
        MockConcept('p7', '가장 작은 소수', _p, anchor: '소수'),
        MockConcept('p8', '에라토스테네스의 체', _m, anchor: '소수'),
      ]),
      MockFolder('divisor', '약수와 인수', concepts: [
        MockConcept('v1', '1의 약수의 개수', _p),
        MockConcept('v2', '인수', _d),
        MockConcept('v3', '소인수분해를 이용하여 약수 구하기', _m),
        MockConcept('v4', '소인수분해를 이용하여 약수의 개수 구하기', _m),
      ]),
      MockFolder('factor', '소인수분해', concepts: [
        MockConcept('f1', '소인수', _d),
        MockConcept('f2', '소인수분해', _d),
        MockConcept('f3', '가지를 뻗어 소인수분해하는 방법', _m, anchor: '소인수분해'),
        MockConcept('f4', '소수로 나누어 소인수분해하는 방법', _m, anchor: '소인수분해'),
        MockConcept('f5', '소인수분해 결과의 표기', _n, anchor: '소인수분해'),
        MockConcept('f6', '소인수분해 결과의 유일성', _p, anchor: '소인수분해'),
        MockConcept('f7', '소인수분해 결과에서 소인수 구하기', _m, anchor: '소인수'),
        MockConcept('f8', '제곱인 수 만들기', _m, anchor: '소인수분해'),
      ]),
      MockFolder('gcdlcm', '약수와 배수', concepts: [
        MockConcept('g1', '공약수', _d),
        MockConcept('g2', '최대공약수', _d),
        MockConcept('g3', '공약수와 최대공약수의 약수', _p, anchor: '최대공약수'),
        MockConcept('g4', '서로소', _d),
        MockConcept('g5', '서로소인 두 수의 공약수', _p, anchor: '서로소'),
        MockConcept('g6', '1과 자연수의 서로소 관계', _p, anchor: '서로소'),
        MockConcept('g7', '서로 다른 두 소수의 서로소 관계', _p, anchor: '서로소'),
        MockConcept('g8', '소인수분해를 이용하여 최대공약수 구하기', _m, anchor: '최대공약수'),
        MockConcept('g9', '공배수', _d),
        MockConcept('g10', '최소공배수', _d),
        MockConcept('g11', '공배수와 최소공배수의 배수', _p, anchor: '최소공배수'),
        MockConcept('g12', '서로소인 두 자연수의 최소공배수', _p, anchor: '최소공배수'),
        MockConcept('g13', '소인수분해를 이용하여 최소공배수 구하기', _m, anchor: '최소공배수'),
        MockConcept('g14', '최대공약수와 최소공배수가 주어질 때 밑과 지수 구하기', _m, anchor: '최소공배수'),
        MockConcept('g15', '최대공약수로 나타낸 두 수의 최소공배수', _p, anchor: '최소공배수'),
        MockConcept('g16', '두 수의 곱과 최대공약수·최소공배수의 관계', _p, anchor: '최소공배수'),
        MockConcept('g17', '최대공약수', _d, version: '기본-2'),
      ]),
    ]),
    MockFolder('power', '거듭제곱', concepts: [
      MockConcept('w1', '거듭제곱', _d),
      MockConcept('w2', '거듭제곱의 밑', _n, anchor: '거듭제곱'),
      MockConcept('w3', '거듭제곱의 지수', _n, anchor: '거듭제곱'),
      MockConcept('w4', '지수가 1인 거듭제곱의 표기', _n, anchor: '거듭제곱'),
      MockConcept('w5', '1의 거듭제곱', _p, anchor: '거듭제곱'),
      MockConcept('w6', '같은 수를 곱하는 것과 더하는 것의 구별', _c, anchor: '거듭제곱'),
      MockConcept('w7', '같은 수나 문자의 곱을 거듭제곱으로 나타내기', _n, anchor: '거듭제곱'),
    ]),
  ]),
  MockFolder('analysis', '해석', area: true),
  MockFolder('stats', '확률통계', area: true),
  MockFolder('geometry', '기하', area: true),
];

enum MockOrder { flow, math, topic }

class MockConceptGroup {
  const MockConceptGroup(this.title, this.concepts);

  /// 주제 묶음일 때만. 묶을 정의가 폴더에 없으면 '그 밖의 개념'.
  final String? title;
  final List<MockConcept> concepts;
}

/// 폴더 안 칩 순서. 같은 자리면 저장된 순서(교재 흐름)를 지킨다.
List<MockConceptGroup> orderConcepts(List<MockConcept> concepts, MockOrder order) {
  final flow = {for (var i = 0; i < concepts.length; i++) concepts[i].id: i};
  int byRank(MockConcept a, MockConcept b) {
    final r = a.type.rank.compareTo(b.type.rank);
    return r != 0 ? r : flow[a.id]!.compareTo(flow[b.id]!);
  }

  switch (order) {
    case MockOrder.flow:
      return [MockConceptGroup(null, concepts)];
    case MockOrder.math:
      return [MockConceptGroup(null, [...concepts]..sort(byRank))];
    case MockOrder.topic:
      final heads = <String, MockConcept>{};
      for (final c in concepts) {
        if (c.type == MockConceptType.definition && c.version == null) heads.putIfAbsent(c.name, () => c);
      }
      final groups = <String, List<MockConcept>>{for (final h in heads.keys) h: []};
      final rest = <MockConcept>[];
      for (final c in concepts) {
        if (heads[c.name] == c) continue;
        final a = c.anchor ?? (c.type == MockConceptType.definition ? c.name : null);
        if (a != null && groups.containsKey(a)) {
          groups[a]!.add(c);
        } else {
          rest.add(c);
        }
      }
      return [
        for (final e in heads.entries) MockConceptGroup(e.key, [e.value, ...groups[e.key]!..sort(byRank)]),
        if (rest.isNotEmpty) MockConceptGroup('그 밖의 개념', rest..sort(byRank)),
      ];
  }
}
