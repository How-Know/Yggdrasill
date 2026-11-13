import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';

void main() {
  TextbookProblemReviewItem item({
    Map<String, dynamic> renderChecks = const {},
    List<Map<String, dynamic>> findings = const [],
    List<Map<String, dynamic>> concepts = const [
      {'id': 'k1'},
    ],
    List<Map<String, dynamic>> thinkings = const [
      {'code': 't1'},
    ],
    List<Map<String, dynamic>> conceptProposals = const [],
    double score = 2,
    double? arithmeticScore,
    List<String> visualTags = const ['없음'],
    String? aiSolution = '풀이',
    String questionType = '주관식',
    String label = '중',
    String? metaCheckedAt = '2026-11-13T00:00:00Z',
    Map<String, dynamic> metaSources = const {},
    List<Map<String, dynamic>> solutionFigures = const [],
    String qualityStatus = 'clean',
    List<Map<String, dynamic>> consistencyIssues = const [],
  }) =>
      TextbookProblemReviewItem.fromJson({
        'crop_id': 'c1',
        'pb_question_id': 'q1',
        'problem_number': '03',
        'stem': '본문',
        'label': label,
        'question_type': questionType,
        'existing_answer': '6',
        'math_status': 'approved',
        'quality_status': qualityStatus,
        'render_checks': renderChecks,
        'render_checked_at': '2026-11-13T00:00:00Z',
        'findings': findings,
        'concepts': concepts,
        'thinkings': thinkings,
        'concept_proposals': conceptProposals,
        'meta_checked_at': metaCheckedAt,
        'meta_sources': metaSources,
        'concept_score': score,
        'thinking_score': score,
        'arithmetic_score': arithmeticScore ?? score,
        'visual_tags': visualTags,
        'ai_solution': aiSolution,
        'solution_figure_assets': solutionFigures,
        'consistency_issues': consistencyIssues,
      });

  test('그림 크기 비율은 ±10% 를 넘으면 준비됨을 막는다', () {
    expect(item(renderChecks: {'figure_size_ratio': 1.08}).renderBlocksReady, isFalse);
    expect(item(renderChecks: {'figure_size_ratio': 1.12}).renderBlocksReady, isTrue);
    expect(item(renderChecks: {'figure_size_ratio': 0.88}).renderBlocksReady, isTrue);
  });

  test('예전 흐름에서 승인된 문항은 승인 당시 범위(±15%)를 인정한다', () {
    expect(item(renderChecks: {'figure_size_ratio': 1.12}, qualityStatus: 'approved').figureNeedsResize, isFalse);
    expect(item(renderChecks: {'figure_size_ratio': 1.2}, qualityStatus: 'approved').figureNeedsResize, isTrue);
    expect(item(renderChecks: {'figure_size_ratio': 1.12}, qualityStatus: 'clean').figureNeedsResize, isTrue);
  });

  test('해설 그림 판정이 실패면 준비됨을 막고, 비율이 벗어나면 크기 조정 대상이다', () {
    expect(item(renderChecks: {'solution_figures_ok': false}).renderBlocksReady, isTrue);
    final it = item(
      renderChecks: {'solution_figure_size_ratio': 1.2},
      solutionFigures: const [
        {'path': 'a.png', 'width_em': 12},
      ],
    );
    expect(it.solutionFigureNeedsResize, isTrue);
    expect(item(renderChecks: {'solution_figure_size_ratio': 1.2}).solutionFigureNeedsResize, isFalse);
  });

  test('처리하지 않은 교정 의견과 해설 논리 오류는 준비됨을 막는다', () {
    final note = item(findings: const [
      {'id': 'f1', 'error_type': 'solution_logic', 'proposal': {'target': 'correction_note'}},
    ]);
    expect(note.readyBlockers, contains('교정 의견 처리 필요'));
    expect(note.readyBlockers, isNot(contains('해설 논리 오류')));
    final logic = item(findings: const [
      {'id': 'f2', 'error_type': 'solution_logic'},
    ]);
    expect(logic.readyBlockers, contains('해설 논리 오류'));
  });

  test('열린 정합성 지적은 준비됨을 막고 문제 문항으로 보인다', () {
    expect(item().readyBlockers.where((b) => b.startsWith('정합성')), isEmpty);
    expect(item().hasIssue, isFalse);
    final it = item(consistencyIssues: const [
      {'id': 'f1', 'code': 'figure_slots', 'title': '그림 수와 그림 자리 불일치', 'status': 'open'},
      {'id': 'f2', 'code': 'math_delimiters', 'title': '수식 구분자 오류', 'status': 'open'},
    ]);
    expect(it.readyBlockers.where((b) => b.startsWith('정합성')), hasLength(1));
    expect(it.hasIssue, isTrue);
  });

  test('메타 필수 항목이 비면 준비됨이 아니다', () {
    expect(item().missingMeta, isEmpty);
    expect(item().readyBlockers.where((b) => b.startsWith('메타 누락')), isEmpty);
    final it = item(
      concepts: const [],
      thinkings: const [],
      score: 0,
      questionType: '',
      visualTags: const [],
      aiSolution: null,
    );
    expect(it.missingMeta, ['개념 연결', '사고 코드', '난이도', '시각 태그', '문항 유형']);
    expect(it.readyBlockers, contains('메타 누락: 개념 연결, 사고 코드, 난이도, 시각 태그, 문항 유형'));
    expect(item(questionType: '미분류').missingMeta, ['문항 유형']);
  });

  test('예전 후보 목록에서 고른 개념 태그는 단원 기준으로 다시 고르기 전까지 준비됨이 아니다', () {
    final old = item(metaCheckedAt: null);
    expect(old.missingMeta, ['개념 재선정']);
    expect(old.needsMetaPass, isTrue);
    expect(item(metaCheckedAt: null, metaSources: const {'concepts': 'owner', 'thinkings': 'owner'}).needsMetaPass, isFalse);
    expect(item().needsMetaPass, isFalse);
  });

  test('확정 때 만들 새 개념 초안이 있으면 개념 연결로 본다', () {
    final it = item(concepts: const [], conceptProposals: const [
      {'name': '정수의 덧셈의 교환법칙', 'type': '성질', 'near_concept_id': 'k1'},
    ]);
    expect(it.missingMeta, isEmpty);
  });

  test('계산이 없는 문항의 계산 점수 0은 AI 풀이 뒤 판정값이다', () {
    expect(item(arithmeticScore: 0).missingMeta, isEmpty);
    expect(item(arithmeticScore: 0, aiSolution: null).missingMeta, contains('난이도'));
  });

  test('교재 라벨은 크롭 확정 때 확인하므로 빈 라벨은 "없음"이다', () {
    final none = item(label: '');
    expect(none.missingMeta, isEmpty);
    expect(none.labelDisplay, '없음');
    expect(item(label: '대표유형').labelDisplay, '대표유형');
  });

  test('운영자가 글자 정답을 반영 대기에 넣은 그림 정답은 카드·판정에서 글자 정답이다', () {
    TextbookProblemReviewItem imageAnswer({required String answer, Map<String, dynamic> staged = const {}}) =>
        TextbookProblemReviewItem.fromJson({
          'crop_id': 'c1',
          'pb_question_id': 'q1',
          'problem_number': '01',
          'answer_kind': 'image',
          'answer_image_bucket': 'textbook-crops',
          'answer_image_path': 'a/answer.png',
          'existing_answer': answer,
          'staged_changes': staged,
        });
    final saved = imageAnswer(answer: '[image]');
    expect(saved.hasAnswerImage, isTrue);
    expect(saved.isImageAnswer, isTrue);
    final owner = imageAnswer(answer: '(1) 1000, 1500 (2) 정비례한다.', staged: const {
      'answer': '(1) 1000, 1500 (2) 정비례한다.',
      'sources': {'answer': 'owner'},
    });
    expect(owner.hasAnswerImage, isFalse);
    expect(owner.isImageAnswer, isFalse);
    final ai = imageAnswer(answer: '1000, 1500', staged: const {
      'answer': '1000, 1500',
      'sources': {'answer': 'ai'},
    });
    expect(ai.hasAnswerImage, isTrue);
    expect(ai.isImageAnswer, isTrue);
  });

  test('시각 태그: 빈 목록은 누락이고, AI 풀이 뒤에 비어 있으면 메타 보충 대상이다', () {
    expect(item().missingMeta, isEmpty);
    final empty = item(visualTags: const []);
    expect(empty.missingMeta, ['시각 태그']);
    expect(empty.needsVisualTags, isTrue);
    expect(empty.needsMetaPass, isTrue);
    final unsolved = item(visualTags: const [], aiSolution: null);
    expect(unsolved.missingMeta, contains('시각 태그'));
    expect(unsolved.needsMetaPass, isFalse);
    expect(
      item(visualTags: const [], metaSources: const {'concepts': 'owner', 'thinkings': 'owner'}).needsMetaPass,
      isTrue,
    );
  });
}
