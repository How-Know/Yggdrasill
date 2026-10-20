// 문항검수 Preview 목업 데이터. 교재 원문은 넣지 않는다(문항 내용은 지어낸 요약).

enum ReviewAxis { fidelity, validity, output }

extension ReviewAxisText on ReviewAxis {
  String get label => switch (this) {
        ReviewAxis.fidelity => '원본 충실도',
        ReviewAxis.validity => '수학적 타당성',
        ReviewAxis.output => '출력 품질',
      };

  String get hint => switch (this) {
        ReviewAxis.fidelity => '문항·정답·해설 연결, 수식·조건·그림 전사',
        ReviewAxis.validity => '정답, 해설 논리',
        ReviewAxis.output => '문항 그림, A4 배치',
      };
}

enum AxisState { pass, issue, held, unchecked }

enum StageState { done, running, decision, waiting, notReady }

enum FindingState { open, held, applied, edited, dismissed, noted }

enum ManualTarget { answer, solutionRef, correctionNote }

extension ManualTargetText on ManualTarget {
  String get label => switch (this) {
        ManualTarget.answer => '채점 정답',
        ManualTarget.solutionRef => '해설 위치',
        ManualTarget.correctionNote => '교정 의견',
      };
}

class ReviewStage {
  const ReviewStage({
    required this.index,
    required this.title,
    required this.caption,
    required this.state,
    required this.done,
    required this.total,
    this.note = '',
  });

  final int index;
  final String title;
  final String caption;
  final StageState state;
  final int done;
  final int total;
  final String note;
}

class ReviewEvidence {
  const ReviewEvidence(this.label, this.value);

  final String label;
  final String value;
}

class ReviewProposal {
  const ReviewProposal({
    required this.target,
    required this.before,
    required this.after,
    required this.reason,
    required this.changes,
    required this.keeps,
  });

  final ManualTarget target;
  final String before;
  final String after;
  final String reason;
  final String changes;
  final String keeps;
}

class ReviewFinding {
  ReviewFinding({
    required this.id,
    required this.stage,
    required this.axis,
    required this.source,
    required this.blocker,
    required this.title,
    required this.detail,
    this.evidence = const [],
    this.proposal,
    this.howTo = const [],
    this.quickFix,
    this.staleNote,
    this.manualTarget = ManualTarget.answer,
    this.state = FindingState.open,
    this.heldNote = '',
  });

  final String id;
  final int stage;
  final ReviewAxis axis;
  final String source;
  final bool blocker;
  final String title;
  final String detail;
  final List<ReviewEvidence> evidence;
  final ReviewProposal? proposal;

  /// 제안 값이 없을 때 고치는 방법 안내.
  final List<String> howTo;

  /// 제안 없이 바로 누를 수 있는 고침(예: 해설 없음으로 표시).
  final String? quickFix;
  final ManualTarget manualTarget;
  String? staleNote;
  FindingState state;
  String heldNote;

  bool get isActive => state == FindingState.open || state == FindingState.held;
}

class ReviewDecision {
  const ReviewDecision({required this.when, required this.action, required this.detail});

  final String when;
  final String action;
  final String detail;
}

class ReviewItem {
  ReviewItem({
    required this.id,
    required this.corner,
    required this.number,
    required this.unit,
    required this.page,
    required this.solutionPage,
    required this.stem,
    required this.answer,
    required this.aiAnswer,
    required this.aiNote,
    required this.baseAxes,
    this.answerManual = false,
    this.solutionNone = false,
    List<ReviewFinding>? findings,
    List<ReviewDecision>? history,
  })  : findings = findings ?? [],
        history = history ?? [];

  final String id;
  final String corner;
  final String number;
  final String unit;
  final int page;
  final int? solutionPage;
  final String stem;
  String answer;
  final String aiAnswer;
  final String aiNote;
  final Map<ReviewAxis, AxisState> baseAxes;
  bool answerManual;
  bool solutionNone;
  final List<ReviewFinding> findings;
  final List<ReviewDecision> history;

  String get label => '$corner $number';

  bool get needsDecision => findings.any((f) => f.state == FindingState.open);

  bool get held => !needsDecision && findings.any((f) => f.state == FindingState.held);

  AxisState axisState(ReviewAxis axis) {
    if (findings.any((f) => f.axis == axis && f.state == FindingState.open)) return AxisState.issue;
    if (findings.any((f) => f.axis == axis && f.state == FindingState.held)) return AxisState.held;
    return baseAxes[axis] ?? AxisState.unchecked;
  }
}

const reviewScopeBook = '개념+유형 중1-1';
const reviewScopeUnit = 'Ⅰ. 소인수분해';

const reviewStages = <ReviewStage>[
  ReviewStage(index: 0, title: '적재 확인', caption: '정답·해설 위치·문제은행 연결', state: StageState.decision, done: 10, total: 10),
  ReviewStage(index: 1, title: '해설 전사', caption: '원본 해설을 문항별로 저장', state: StageState.running, done: 6, total: 10),
  ReviewStage(index: 2, title: 'AI 독립 풀이', caption: '정답·해설 없이 먼저 풂', state: StageState.done, done: 10, total: 10),
  ReviewStage(index: 3, title: '대조·판정', caption: '원본 정답·해설과 비교', state: StageState.decision, done: 10, total: 10),
  ReviewStage(index: 4, title: '렌더 검수', caption: '문항 그림, A4 배치', state: StageState.waiting, done: 0, total: 10, note: '대조가 끝나면 시작'),
  ReviewStage(index: 5, title: '개념서', caption: '원문 전사·내용 분석 승인', state: StageState.notReady, done: 0, total: 4, note: '준비 전'),
  ReviewStage(index: 6, title: '마감', caption: '놓친 오류·과잉 경고 측정', state: StageState.notReady, done: 0, total: 1, note: '준비 전'),
];

const _passAll = {ReviewAxis.fidelity: AxisState.pass, ReviewAxis.validity: AxisState.pass};

List<ReviewItem> buildReviewMockItems() => [
      ReviewItem(
        id: 'b3',
        corner: '필수 문제',
        number: '3',
        unit: '소인수분해 › 약수와 그 개수',
        page: 12,
        solutionPage: 34,
        stem: '거듭제곱으로 나타낸 수의 약수 개수를 구하는 문제',
        answer: '24',
        aiAnswer: '12',
        aiNote: '2³×3² → (3+1)×(2+1) = 12',
        baseAxes: const {ReviewAxis.validity: AxisState.pass},
        findings: [
          ReviewFinding(
            id: 'b3-1',
            stage: 3,
            axis: ReviewAxis.fidelity,
            source: 'AI 대조',
            blocker: true,
            title: '채점 정답이 이웃 문항(필수 문제 4)의 정답으로 보임',
            detail: 'AI 독립 풀이는 12입니다. 저장된 정답 24는 필수 문제 4의 정답과 같고, '
                '정답지 34쪽 3번 상자의 값은 12입니다.',
            evidence: const [
              ReviewEvidence('저장된 정답', '24'),
              ReviewEvidence('AI 독립 풀이', '12 · 확신 높음'),
              ReviewEvidence('정답지 34쪽 3번', '12'),
              ReviewEvidence('필수 문제 4 정답', '24'),
            ],
            proposal: const ReviewProposal(
              target: ManualTarget.answer,
              before: '24',
              after: '12',
              reason: '정답지 원본(34쪽 3번)과 AI 독립 풀이가 같습니다.',
              changes: '학생 채점 정답. 이미 채점된 기록은 그대로 둡니다.',
              keeps: '교재 원본과 해설, 필수 문제 4의 정답',
            ),
          ),
        ],
      ),
      ReviewItem(
        id: 'b6',
        corner: '필수 문제',
        number: '6',
        unit: '소인수분해 › 소인수분해',
        page: 13,
        solutionPage: 34,
        stem: '자연수를 소인수의 곱으로 나타내는 문제',
        answer: '2²×3×5',
        aiAnswer: '2²×3×5',
        aiNote: '60 = 2×2×3×5',
        baseAxes: const {ReviewAxis.validity: AxisState.pass},
        findings: [
          ReviewFinding(
            id: 'b6-1',
            stage: 3,
            axis: ReviewAxis.fidelity,
            source: 'AI 대조',
            blocker: true,
            title: '정답 전사가 정답지와 다름',
            detail: '정답지에는 2²×3×5로 적혀 있는데 저장된 정답은 2²×15였습니다.',
            evidence: const [
              ReviewEvidence('정답지 34쪽 6번', '2²×3×5'),
              ReviewEvidence('제안 당시 저장된 정답', '2²×15'),
            ],
            proposal: const ReviewProposal(
              target: ManualTarget.answer,
              before: '2²×15',
              after: '2²×3×5',
              reason: '정답지 원본 표기와 맞춥니다.',
              changes: '학생 채점 정답',
              keeps: '교재 원본과 해설',
            ),
            staleNote: '이 제안을 만든 뒤 정답이 바뀌었습니다(VLM 재실행 · 10/14 23:41). '
                '제안 당시 2²×15, 지금 2²×3×5. 옛 값 기준 제안이라 그대로 반영할 수 없습니다. '
                '지금 값이 맞으면 "문제 없음", 다르면 "직접 고치기"를 누르세요.',
          ),
        ],
      ),
      ReviewItem(
        id: 'a11',
        corner: '개념확인',
        number: '11쪽',
        unit: '소인수분해 › 소수와 합성수',
        page: 11,
        solutionPage: null,
        stem: '주어진 수 가운데 소수를 고르는 문제',
        answer: '②, ④',
        aiAnswer: '②, ④',
        aiNote: '약수가 1과 자기 자신뿐인 수',
        baseAxes: const {ReviewAxis.validity: AxisState.pass},
        findings: [
          ReviewFinding(
            id: 'a11-1',
            stage: 0,
            axis: ReviewAxis.fidelity,
            source: '자동 점검',
            blocker: false,
            title: '해설 위치가 없음',
            detail: '해설지에서 이 문항의 해설 위치를 찾지 못했습니다. 이 교재의 개념확인은 정답만 있고 상세 해설이 없습니다.',
            evidence: const [ReviewEvidence('해설지 33~34쪽', '개념확인 11쪽 풀이 없음')],
            howTo: const [
              '해설이 원래 없는 문항이면 "해설 없음으로 표시"를 누릅니다.',
              '해설이 있는데 못 찾았으면 교재 단계 창에서 위치를 지정합니다.',
            ],
            quickFix: '해설 없음으로 표시',
            manualTarget: ManualTarget.solutionRef,
          ),
        ],
      ),
      ReviewItem(
        id: 'd7',
        corner: '탄탄 단원 다지기',
        number: '7',
        unit: '소인수분해 › 약수와 그 개수',
        page: 18,
        solutionPage: 36,
        stem: '조건을 만족하는 가장 작은 자연수를 구하는 문제',
        answer: '18',
        aiAnswer: '18',
        aiNote: '2×3² = 18',
        baseAxes: const {ReviewAxis.fidelity: AxisState.pass},
        findings: [
          ReviewFinding(
            id: 'd7-1',
            stage: 3,
            axis: ReviewAxis.validity,
            source: 'AI 대조',
            blocker: false,
            title: '원본 해설의 계산 실수 의심',
            detail: '해설 셋째 줄에 2×3² = 36으로 적혀 있지만 18입니다. 최종 정답 18은 맞습니다.',
            evidence: const [
              ReviewEvidence('해설 셋째 줄', '2×3² = 36'),
              ReviewEvidence('AI 계산', '18'),
              ReviewEvidence('채점 정답', '18 · 맞음'),
            ],
            proposal: const ReviewProposal(
              target: ManualTarget.correctionNote,
              before: '없음',
              after: '해설 셋째 줄 2×3² = 36 → 18 (원본 오기)',
              reason: '정답은 맞고 해설 중간 계산만 틀렸습니다.',
              changes: '교정 의견만 저장합니다(직원 화면에 표시).',
              keeps: '교재 원본 해설과 채점 정답',
            ),
            manualTarget: ManualTarget.correctionNote,
          ),
        ],
      ),
      ReviewItem(
        id: 'e1',
        corner: '쓱쓱 서술형',
        number: '1',
        unit: '소인수분해 › 제곱인 수',
        page: 19,
        solutionPage: 37,
        stem: '그림의 정사각형 넓이로 제곱인 수를 만드는 서술형',
        answer: '풀이 과정 채점',
        aiAnswer: '판정 못 함',
        aiNote: '그림의 선분 길이를 읽지 못했습니다',
        baseAxes: const {ReviewAxis.fidelity: AxisState.pass},
        findings: [
          ReviewFinding(
            id: 'e1-1',
            stage: 3,
            axis: ReviewAxis.validity,
            source: 'AI 대조',
            blocker: false,
            title: 'AI가 판정하지 못함: 그림의 길이를 읽지 못함',
            detail: '문항 그림의 선분 길이가 흐려 독립 풀이를 확정하지 못했습니다. 사람이 판정해 주세요.',
            evidence: const [ReviewEvidence('AI 판정', '보류 · 그림 판독 실패')],
            howTo: const [
              '원본 PDF에서 문항을 보고 직접 판정합니다.',
              '맞으면 "문제 없음", 정답이 틀렸으면 "직접 고치기"를 누릅니다.',
            ],
            state: FindingState.held,
            heldNote: '원본 PDF 확인 후 결정',
          ),
        ],
      ),
      ReviewItem(
        id: 'c2',
        corner: '쏙쏙 개념 익히기',
        number: '2',
        unit: '소인수분해 › 소인수분해',
        page: 14,
        solutionPage: 35,
        stem: '소인수분해 결과로 알맞은 것을 고르는 문제',
        answer: '④',
        aiAnswer: '④',
        aiNote: '84 = 2²×3×7',
        baseAxes: const {ReviewAxis.validity: AxisState.pass},
        findings: [
          ReviewFinding(
            id: 'c2-1',
            stage: 0,
            axis: ReviewAxis.fidelity,
            source: '자동 점검',
            blocker: false,
            title: '문제은행 정답과 채점 정답이 다름',
            detail: '학생 채점은 교재 정답 ④를 씁니다. 문제은행 사본은 ③입니다. 한쪽만 고쳐졌을 수 있습니다.',
            evidence: const [
              ReviewEvidence('채점 정답(교재)', '④'),
              ReviewEvidence('문제은행 사본', '③'),
              ReviewEvidence('AI 독립 풀이', '④'),
            ],
            howTo: const [
              '정답지 원본을 보고 맞는 쪽을 정합니다.',
              '채점 정답이 틀렸으면 "직접 고치기"로 고칩니다. 문제은행 사본은 문제은행 화면에서 고칩니다.',
            ],
          ),
        ],
      ),
      ReviewItem(
        id: 'b1',
        corner: '필수 문제',
        number: '1',
        unit: '소인수분해 › 소수와 합성수',
        page: 12,
        solutionPage: 34,
        stem: '소수와 합성수의 성질 가운데 옳은 것을 고르는 문제',
        answer: '④',
        aiAnswer: '④',
        aiNote: '1은 소수도 합성수도 아님',
        baseAxes: _passAll,
        answerManual: true,
        history: const [
          ReviewDecision(when: '10/14 22:10', action: '직접 고침', detail: '채점 정답 ③ → ④ · 정답지 34쪽 확인'),
        ],
      ),
      ReviewItem(
        id: 'b2',
        corner: '필수 문제',
        number: '2',
        unit: '소인수분해 › 거듭제곱',
        page: 12,
        solutionPage: 34,
        stem: '같은 수의 곱을 거듭제곱으로 나타내는 문제',
        answer: '3⁴',
        aiAnswer: '3⁴',
        aiNote: '3을 네 번 곱함',
        baseAxes: _passAll,
      ),
      ReviewItem(
        id: 'c3',
        corner: '쏙쏙 개념 익히기',
        number: '3',
        unit: '소인수분해 › 소인수분해',
        page: 14,
        solutionPage: 35,
        stem: '소인수를 모두 구하는 문제',
        answer: '2, 3, 7',
        aiAnswer: '2, 3, 7',
        aiNote: '126 = 2×3²×7',
        baseAxes: _passAll,
      ),
      ReviewItem(
        id: 'd2',
        corner: '탄탄 단원 다지기',
        number: '2',
        unit: '소인수분해 › 약수와 그 개수',
        page: 17,
        solutionPage: 36,
        stem: '약수의 개수가 같은 수를 고르는 문제',
        answer: '③',
        aiAnswer: '③',
        aiNote: '(a+1)(b+1) 비교',
        baseAxes: _passAll,
      ),
    ];
