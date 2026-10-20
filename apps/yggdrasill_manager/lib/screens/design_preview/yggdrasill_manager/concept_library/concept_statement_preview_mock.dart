/// 개념 상세 "여러 서술" Preview 목업. 설계·시험용 예시이고 실제 교재의 문장·등장 학년을 확인한 자료가 아니다.
class MockStatement {
  const MockStatement({
    required this.id,
    required this.title,
    required this.body,
    required this.status,
    this.base = false,
    this.approach,
    this.conditions,
    this.conditionsInSource,
    this.terms = const [],
    this.verbatim = false,
    this.quote,
    this.supplementNote,
    this.unverifiedNote,
    this.sources = const [],
    this.appearances = const [],
  });

  final String id;

  /// 기존 개념 본문(concepts.content). 서술 표에는 없고 고치면 기존 개념 수정 창으로 간다.
  final bool base;
  final String title;
  final String body;
  final String status;
  final String? approach;
  final String? conditions;
  final String? conditionsInSource;
  final List<String> terms;
  final bool verbatim;
  final String? quote;
  final String? supplementNote;
  final String? unverifiedNote;
  final List<String> sources;
  final List<String> appearances;

  String get chipLabel => base ? '기본 · 개념 본문' : (approach ?? title);
}

const kMockConceptName = '등가능한 유한 경우에서의 확률';

const kMockCore = (
  status: '확정 v1',
  meaning: '가능한 결과가 유한하고 각 결과가 일어날 가능성이 같을 때, 사건이 일어날 가능성을 결과의 개수 비율로 나타낸 값',
  scope: '유한하고 등가능한 경우에만. 상위 개념 "확률" 전체의 조건이 아니다.',
  conditions: '가능한 결과가 유한하며 하나 이상 · 각 결과가 일어날 가능성이 같음',
);

const kMockStatements = [
  MockStatement(
    id: 'base',
    base: true,
    title: '기본 서술',
    body: '(사건 A가 일어나는 경우의 수) ÷ (일어날 수 있는 모든 경우의 수)',
    status: '기존 개념 본문 · 원문 여부 기록 없음',
    sources: ['개념+유형 중2-2 · 확률 > 확률의 뜻 · 120쪽 (PDF 122쪽)'],
    appearances: ['교육과정 판 미기록 · 중 2-2 · 확률'],
  ),
  MockStatement(
    id: 'a',
    title: '경우의 수로 본 확률',
    body: '모든 경우가 일어날 가능성이 같을 때, 전체 경우의 수에 대한 사건이 일어나는 경우의 수의 비율',
    status: '확정 v1',
    approach: '경우의 수',
    conditions: '가능한 결과가 유한하고, 각 결과가 일어날 가능성이 같다.',
    conditionsInSource: '원문에 안 보임 · 앞뒤 문맥 확인 필요',
    terms: ['경우의 수', '사건'],
    supplementNote: '원문 식 옆에 조건이 보이지 않아 공통 조건을 조건 칸에 적었다.',
    unverifiedNote: '단원 첫머리 전제에 "가능성이 같다"가 있는지 아직 확인하지 않음',
    sources: ['개념원리 중2-2 · 확률 > 확률의 뜻 · 98쪽 (PDF 100쪽)'],
    appearances: ['2022 개정 · 중 2-2 · 확률'],
  ),
  MockStatement(
    id: 'b',
    title: '표본공간으로 본 확률',
    body: r'유한한 표본공간 $S$에서 각 근원사건의 발생 가능성이 같고 $A \subset S$일 때 $P(A)=\frac{n(A)}{n(S)}$',
    status: '확정 v2 · 저장된 초안 있음',
    approach: '집합과 기호',
    conditions: '표본공간이 유한하고 각 근원사건의 발생 가능성이 같다.',
    conditionsInSource: '원문에 조건이 적혀 있음',
    terms: ['표본공간', '근원사건', '사건'],
    verbatim: true,
    quote: r'어떤 시행에서 표본공간 $S$의 각 근원사건이 일어날 가능성이 모두 같을 때, …',
    sources: [
      '개념원리 확률과 통계 · 확률 > 확률의 뜻과 활용 · 40쪽 (PDF 42쪽)',
      '개념원리 확률과 통계 · 확률 > 확률의 뜻과 활용 · 41쪽 (PDF 43쪽)',
    ],
    appearances: ['2015 개정 · 고 확률과 통계 · 확률', '2022 개정 · 고 확률과 통계 · 확률'],
  ),
];
