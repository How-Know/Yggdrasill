import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yggdrasill_manager/screens/skill/thinking_foundation_screen.dart';
import 'package:yggdrasill_manager/services/thinking_foundation_service.dart';

class _FakeThinkingFoundationService extends ThinkingFoundationService {
  _FakeThinkingFoundationService(this._seed)
      : super(
          client: SupabaseClient(
            'http://localhost',
            'fake-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          ),
        );

  List<ThinkingFoundationItem> _seed;

  @override
  Future<List<ThinkingFoundationItem>> fetchAll() async => List.of(_seed);

  @override
  Future<void> save({
    String? id,
    required String code,
    required String groupCode,
    required String title,
    required String definition,
    required List<String> learningGoals,
    required String teachingPrinciple,
    required String observationCriteria,
    required List<String> keywords,
    required List<ThinkingFoundationExample> examples,
    required int sortOrder,
    required bool isActive,
  }) async {
    final next = ThinkingFoundationItem(
      id: id ?? 'new-$code',
      code: code,
      domain: 'C',
      groupCode: groupCode,
      groupTitle: thinkingFoundationGroupOf(groupCode).title,
      title: title,
      definition: definition,
      learningGoals: learningGoals,
      teachingPrinciple: teachingPrinciple,
      observationCriteria: observationCriteria,
      keywords: keywords,
      examples: examples,
      sortOrder: sortOrder,
      isActive: isActive,
    );
    if (id == null) {
      _seed = [..._seed, next];
    } else {
      _seed = [for (final x in _seed) x.id == id ? next : x];
    }
  }
}

List<ThinkingFoundationItem> _build12SeedItems() {
  final specs = <(String, String, String, String, String)>[
    ('C1-01', 'C1', '의미의 명확성', '기호와 용어의 의미를 분명히 인식한다.', '역함수'),
    ('C1-02', 'C1', '조건의 존중', '성립 조건을 임의로 무시하지 않는다.', '분모 0'),
    ('C1-03', 'C1', '기준의 일관성', '정한 기준을 임의로 바꾸지 않는다.', '부등호 방향'),
    ('C1-04', 'C1', '표현의 정확성', '의미가 왜곡되지 않게 표현한다.', '근삿값'),
    ('C2-05', 'C2', '근거 중심 판단', '타당한 수학적 근거로 판단한다.', '정당화'),
    ('C2-06', 'C2', '일반화의 절제', '일부 사례만으로 법칙화하지 않는다.', '성급한 일반화'),
    ('C2-07', 'C2', '반례의 수용', '유효한 반례가 있으면 주장을 수정한다.', '소수 2'),
    ('C2-08', 'C2', '검증의 책임', '결론이 원래 조건을 만족하는지 확인한다.', '무연근'),
    ('C3-09', 'C3', '지적 자율성', '권위에만 의존하지 않고 근거로 판단한다.', '합리적 반박'),
    ('C3-10', 'C3', '불확실성의 인정과 질문', '모르는 지점을 구체적인 질문으로 표현한다.', '판단 유보'),
    ('C3-11', 'C3', '오류 수용과 수정', '오류 원인을 분석해 풀이를 수정한다.', '첫 오류 단계'),
    ('C3-12', 'C3', '유연한 지속성', '막히면 다른 전략으로 전환하며 지속한다.', '보조선'),
  ];

  return [
    for (var i = 0; i < specs.length; i++)
      ThinkingFoundationItem(
        id: 'id-${specs[i].$1}',
        code: specs[i].$1,
        domain: 'C',
        groupCode: specs[i].$2,
        groupTitle: thinkingFoundationGroupOf(specs[i].$2).title,
        title: specs[i].$3,
        definition: specs[i].$4,
        learningGoals: const ['목표 1', '목표 2', '목표 3'],
        teachingPrinciple: '${specs[i].$3} 핵심 발문',
        observationCriteria: '${specs[i].$3} 관찰 기준',
        keywords: [specs[i].$5],
        examples: [
          ThinkingFoundationExample(id: 'ex-$i-1', exampleOrder: 1, content: '${specs[i].$1} 예시 1 (${specs[i].$5})'),
          ThinkingFoundationExample(id: 'ex-$i-2', exampleOrder: 2, content: '${specs[i].$1} 예시 2'),
          ThinkingFoundationExample(id: 'ex-$i-3', exampleOrder: 3, content: '${specs[i].$1} 예시 3'),
        ],
        sortOrder: i + 1,
        isActive: true,
      ),
  ];
}

void main() {
  test('C3 역량 연결은 정적 문항 관찰(static_item)을 허용하지 않고 풀이 과정 관찰로 보정한다', () {
    final c3Link = QuestionFoundationLink.fromJson({
      'foundation_id': 'id-C3-09',
      'code': 'C3-09',
      'group_code': 'C3',
      'group_title': '탐구의 태도',
      'title': '지적 자율성',
      'relevance_level': 'core',
      'observability': 'static_item',
    });
    expect(c3Link.observability, 'process_required');
    expect(c3Link.copyWith(observability: 'static_item').observability, 'process_required');
  });

  testWidgets('사고의 토대 화면: 12개 역량·그룹별 4개·예시 3개 표시 및 키워드/예시 검색', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final svc = _FakeThinkingFoundationService(_build12SeedItems());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 920,
            height: 780,
            child: ThinkingFoundationScreen(service: svc),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('전체 (12)'), findsOneWidget);
    expect(find.text('C1 규범 (4)'), findsOneWidget);
    expect(find.text('C2 판단 (4)'), findsOneWidget);
    expect(find.text('C3 태도 (4)'), findsOneWidget);
    expect(find.byKey(const ValueKey('foundation-group-C1')), findsOneWidget);
    expect(find.byKey(const ValueKey('foundation-group-C2')), findsOneWidget);
    expect(find.byKey(const ValueKey('foundation-group-C3')), findsOneWidget);

    // 기본 첫 항목(C1-01)의 상세 정보와 예시 3개 표시 확인
    expect(find.text('수학적 예시 (3)'), findsOneWidget);
    expect(find.textContaining('C1-01 예시 1', findRichText: true), findsOneWidget);
    expect(find.textContaining('C1-01 예시 2', findRichText: true), findsOneWidget);
    expect(find.textContaining('C1-01 예시 3', findRichText: true), findsOneWidget);

    // 예시·키워드 내용으로 검색 (무연근 -> C2-08 검증의 책임)
    await tester.enterText(find.byType(TextField).first, '무연근');
    await tester.pumpAndSettle();
    expect(find.text('표시 1개'), findsOneWidget);
    expect(find.byKey(const ValueKey('foundation-item-C2-08')), findsOneWidget);

    // C3 항목 클릭 시 정적 문항 직접 측정 주의 안내 노출 확인
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('foundation-item-C3-09')));
    await tester.pumpAndSettle();
    expect(find.textContaining('C3(탐구의 태도)는 정적 문항 내용만으로 측정하기 어려우므로'), findsOneWidget);
  });
}
