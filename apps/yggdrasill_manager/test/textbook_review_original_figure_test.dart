import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';
import 'package:yggdrasill_manager/services/textbook_review_solution_image_service.dart';

TextbookProblemReviewItem _item(Map<String, dynamic> m) => TextbookProblemReviewItem.fromJson({
      'crop_id': 'c1',
      'raw_page': 12,
      'item_region_1k': [100, 50, 400, 950],
      'stem': '다음 그림에서 x의 값을 구하여라.[그림]',
      'quality_status': 'issue',
      ...m,
    });

void main() {
  group('그림 도우미', () {
    test('문항 그림이 아닌 그림 빼기: 붙어 있는 번호만 제안하고, 자산·배치·묶음에서 뺀다', () {
      final assets = [
        {'figure_index': 1, 'path': 'a.png'},
        {'figure_index': 2, 'path': 'b.png'},
        {'figure_index': 2, 'path': 'b2.png'},
      ];
      final item = _item({
        'pb_figure_assets': assets,
        'fix_proposal': {'figure_removals': [2, 3], 'applied_at': '2026-11-12T00:00:00Z'},
      });
      expect(item.proposedFigureRemovals, [2]);
      final next = withoutFigures(assets, {
        'version': 1,
        'items': [
          {'assetKey': 'idx:1', 'widthEm': 10},
          {'assetKey': 'idx:2', 'widthEm': 8},
        ],
        'groups': [
          {'type': 'horizontal', 'members': ['idx:1', 'idx:2']},
        ],
      }, {2});
      expect(next.assets.map((a) => a['path']), ['a.png']);
      expect((next.layout['items'] as List).map((e) => (e as Map)['assetKey']), ['idx:1']);
      expect(next.layout['groups'], isEmpty);
    });

    test('본문에 자리가 없어 보류한 원본 그림은 아직 붙지 않은 번호만 확인 대상으로 내고 자동 크롭에는 넣지 않는다', () {
      final item = _item({
        'pb_figure_assets': [
          {'figure_index': 1, 'path': 'a.png'},
        ],
        'fix_proposal': {
          'figure_crops': [],
          'figure_crops_unslotted': [
            {'figure_index': 1, 'bbox_1k': [0, 0, 10, 10], 'reason': 'missing'},
            {'figure_index': 2, 'bbox_1k': [400, 550, 700, 950], 'reason': 'missing'},
          ],
        },
      });
      expect(item.unslottedFigureCrops.map((c) => c['figure_index']), [2]);
      expect(item.proposedFigureCrops, isEmpty);
    });

    test('figureMarkerCount 는 V2 그림 자리 표시를 센다', () {
      expect(figureMarkerCount('가[그림]나[도형]다[도표]라[[PB_FIG_abc]]'), 4);
      expect(figureMarkerCount('그림 없음'), 0);
    });

    test('orderedFigureAssets 는 번호마다 승인 우선·최신 우선 하나를 번호 순으로 고른다', () {
      final out = orderedFigureAssets([
        {'figure_index': 2, 'approved': false, 'created_at': '2026-01-02', 'path': 'b-old'},
        {'figure_index': 1, 'approved': true, 'created_at': '2026-01-01', 'path': 'a'},
        {'figure_index': 2, 'approved': false, 'created_at': '2026-01-03', 'path': 'b-new'},
        {'figure_index': 0, 'path': 'skip'},
        {'figure_index': 1, 'approved': false, 'created_at': '2026-02-01', 'path': 'a-unapproved'},
      ]);
      expect(out.map((a) => a['path']), ['a', 'b-new']);
    });

    test('cropBoxToPageRegion 은 원본 이미지 안 상자를 쪽 좌표로 바꾼다', () {
      expect(cropBoxToPageRegion([100, 0, 600, 1000], [0, 0, 1000, 1000], margin: 0), [100, 0, 600, 1000]);
      expect(cropBoxToPageRegion([100, 200, 300, 600], [500, 500, 1000, 1000], margin: 0), [200, 400, 300, 600]);
      expect(cropBoxToPageRegion([0, 0, 1000, 1000], [5, 5, 995, 995]), [0, 0, 1000, 1000]);
      expect(cropBoxToPageRegion([100, 0, 100, 1000], [0, 0, 1000, 1000]), isNull);
      expect(cropBoxToPageRegion([1, 2, 3], [0, 0, 10, 10]), isNull);
    });

    test('figureLayoutSignature 는 키 순서·항목 순서·정수/실수 차이를 무시한다', () {
      final a = {
        'items': [
          {'assetKey': 'idx:1', 'widthEm': 12, 'position': 'below-stem', 'anchor': 'center'},
          {'assetKey': 'idx:2', 'widthEm': 8.0, 'position': 'inline-right', 'anchor': 'right'},
        ],
      };
      final b = {
        'version': 1,
        'items': [
          {'anchor': 'right', 'position': 'inline-right', 'widthEm': 8, 'assetKey': 'idx:2', 'offsetXEm': 0},
          {'widthEm': 12.0, 'assetKey': 'idx:1', 'anchor': 'center', 'position': 'below-stem'},
        ],
      };
      expect(figureLayoutSignature(a), figureLayoutSignature(b));
      expect(
        figureLayoutSignature(a) ==
            figureLayoutSignature({
              'items': [
                {'assetKey': 'idx:1', 'widthEm': 13},
              ],
            }),
        isFalse,
      );
      expect(figureLayoutSignature(null), '');
    });

    test('scaleFigureLayout 은 폭을 배율만큼 바꾸고 4~40em·0.5 단위로 맞춘다', () {
      final layout = <String, dynamic>{
        'version': 1,
        'items': [
          {'assetKey': 'idx:1', 'widthEm': 20, 'position': 'below-stem'},
          {'assetKey': 'idx:2', 'widthEm': 38},
        ],
        'groups': [],
      };
      expect(figureLayoutItems(scaleFigureLayout(layout, 1 / 1.6)).map((x) => x['widthEm']), [12.5, 24]);
      expect(figureLayoutItems(scaleFigureLayout(layout, 3)).map((x) => x['widthEm']), [40, 40]);
      final only = scaleFigureLayout(layout, 0.5, keys: {'idx:2'});
      expect(figureLayoutItems(only).map((x) => x['widthEm']), [20, 19]);
      expect(figureLayoutItems(only).first['position'], 'below-stem');
      expect(only['groups'], isEmpty);
      // 기존 pb_figure_layout 이 비어 있어도 fallbackCount/fallbackAssets 가 있으면 기본 20em 에서 배율(예: 1/1.3)만큼 줄인 항목을 만든다
      final fromEmpty = scaleFigureLayout(const {}, 1 / 1.3, fallbackCount: 1);
      expect(figureLayoutItems(fromEmpty).map((x) => x['widthEm']), [15.5]);
    });
  });

  group('문항 상태', () {
    test('엔진 보류를 승인한 뒤의 남은 렌더 이상 판정은 준비됨을 막지 않고, 승인 뒤 다시 판정한 이상은 막는다', () {
      const rc = {'problem_ok': true, 'fidelity_ok': false};
      expect(_item({'render_checks': rc, 'render_checked_at': '2026-11-11T17:19:13Z'}).renderBlocksReady, isTrue);
      final accepted = _item({
        'render_checks': rc,
        'render_checked_at': '2026-11-11T17:19:13Z',
        'engine_resolved_at': '2026-11-12T07:17:29Z',
      });
      expect(accepted.renderBlocksReady, isFalse);
      expect(accepted.renderHasIssue, isTrue);
      expect(
        _item({
          'render_checks': rc,
          'render_checked_at': '2026-11-12T08:00:00Z',
          'engine_resolved_at': '2026-11-12T07:17:29Z',
        }).renderBlocksReady,
        isTrue,
      );
    });

    test('needsFixPass: 원본 좌표가 있는 오류·그림 문항만, 아직 안 돌렸거나 수정 후에도 오류일 때', () {
      expect(_item({}).needsFixPass, isTrue);
      expect(_item({'item_region_1k': []}).needsFixPass, isFalse);
      expect(_item({'quality_status': 'approved'}).needsFixPass, isFalse);
      // 품질 승인 뒤라도 2단계/4단계에서 지시문 누락·원본 불일치가 남아 있고 아직 원본 대조 재검수로 덮어쓰이지 않았으면 수정 대상
      expect(_item({'quality_status': 'approved', 'quality_checks': {'stem_ok': false}}).needsFixPass, isTrue);
      expect(
        _item({
          'quality_status': 'approved',
          'quality_checks': {'stem_ok': false},
          'render_checked_at': '2026-11-03T02:00:00Z',
          'render_checks': {'original_compared': true, 'problem_ok': true, 'fidelity_ok': true},
        }).needsFixPass,
        isFalse,
      );
      expect(_item({'quality_status': 'clean', 'stem': '그림 없음'}).needsFixPass, isFalse);
      expect(_item({'quality_status': 'clean'}).needsFixPass, isTrue);
      const ran = {'fix_pass_at': '2026-11-03T01:00:00Z', 'text_matches_original': true};
      expect(_item({'fix_proposal': ran}).needsFixPass, isFalse);
      expect(_item({'fix_proposal': {...ran, 'applied_at': '2026-11-03T02:00:00Z'}}).needsFixPass, isTrue);
      // 이전 fix_pass 에서 수정안을 못 냈고(text_matches_original != true) 여전히 오류로 남아 있으면 다시 돌린다
      expect(_item({'fix_proposal': {'fix_pass_at': '2026-11-03T01:00:00Z'}}).needsFixPass, isTrue);
      expect(
        _item({'quality_status': 'clean', 'fix_proposal': {...ran, 'applied_at': '2026-11-03T02:00:00Z'}}).needsFixPass,
        isFalse,
      );
    });

    test('hasPendingFixProposal 과 computeCommonStemFix: 공통 발문만 바뀐 제안도 잡고 숫자·식 첫 문단으로 잘못 줄이지 않는다', () {
      expect(
        _item({'fix_proposal': {'common_stem': '다음 수의 약수의 개수를 구하여라.'}}).hasPendingFixProposal,
        isTrue,
      );
      const tableStem = r'다음 표의 빈칸에 알맞은 수를 써넣어라.[문단]15=3\times5[표시작]×|1[표끝]';
      final fixed = computeCommonStemFix('36=2^{2}\\times3^{2}\n[문단]\n$tableStem', tableStem);
      expect(fixed?.commonStem, '다음 표의 빈칸에 알맞은 수를 써넣어라.');
      expect(fixed?.stem, r'15=3\times5[표시작]×|1[표끝]');
      expect(computeCommonStemFix(r'36=2^{2}\times3^{2}', tableStem)?.commonStem, '다음 표의 빈칸에 알맞은 수를 써넣어라.');
      expect(computeCommonStemFix('36', '36\n480'), isNull);
    });

    test('cleanSolutionTranscribedText 와 resolvedMathAnswer: [해설]·정답 줄 이중 추출을 제거하고 정답 수정안을 우선 쓴다', () {
      expect(
        cleanSolutionTranscribedText(
          '16 답 \$\\times\$\n\$\\boxed{2}\$는 소수이지만, 나머지 짝수는 합성수이다.',
          problemNumber: '16',
          solutionAnswer: r'$\times$',
        ),
        r'$\boxed{2}$는 소수이지만, 나머지 짝수는 합성수이다.',
      );
      expect(
        cleanSolutionTranscribedText('[정답] ③\n[해설]\n풀이 본문', problemNumber: '03', solutionAnswer: '③'),
        '풀이 본문',
      );
      final withProp = _item({
        'math_status': 'issue',
        'existing_answer': '',
        'fix_proposal': {'proposed_answer': '1, 3, 5, 15'},
      });
      expect(withProp.resolvedMathAnswer, '1, 3, 5, 15');

      // 빈칸형 문항에서 도형 외 단독 빈칸 오판은 stage2TextSuperseded 로 숨긴다
      final blankItem = _item({
        'stem': r'90을 소인수분해 하는 과정이다. □ 안에 알맞은 수를 써넣어라.[그림]\Rightarrow 90=2\times\square\times5',
        'quality_checks': {
          'issue_title': '도형 외에 용도가 불명확한 빈칸이 추가됨',
          'issue_detail': '결론 식 위에 단독 빈칸이 하나 더 보입니다.',
        },
        'render_checks': {'original_compared': true, 'problem_ok': true, 'fidelity_ok': true, 'figure_size_ratio': 1.3},
        'render_checked_at': '2026-11-03T02:00:00Z',
      });
      expect(blankItem.isFillInBlank, isTrue);
      expect(blankItem.stage2TextSuperseded, isTrue);

      // appliedFixSummary 는 DB 에 반영된 수정 필드와 메모를 한 줄로 요약한다
      final appliedItem = _item({
        'fix_proposal': {
          'applied_at': '2026-11-03T05:00:00Z',
          'applied_fields': ['common_stem', 'figure_layout'],
          'applied_note': '그림 크기 원본 비율(1.0배) 자동 조정',
        },
      });
      expect(
        appliedItem.appliedFixSummary,
        '공통 발문·그림 크기·배치 DB 반영 완료 — 그림 크기 원본 비율(1.0배) 자동 조정',
      );
    });

    test('hasPendingFigureProposal: 배치가 지금과 다르거나 잘라 등록할 그림이 있고 아직 적용 전', () {
      final cur = {
        'items': [
          {'assetKey': 'idx:1', 'widthEm': 20, 'position': 'below-stem', 'anchor': 'center'},
        ],
      };
      final same = {
        'items': [
          {'assetKey': 'idx:1', 'widthEm': 20.0, 'position': 'below-stem', 'anchor': 'center'},
        ],
      };
      final diff = {
        'items': [
          {'assetKey': 'idx:1', 'widthEm': 12, 'position': 'inline-right', 'anchor': 'right'},
        ],
      };
      expect(_item({'pb_figure_layout': cur, 'fix_proposal': {'figure_layout': same}}).hasPendingFigureProposal, isFalse);
      expect(_item({'pb_figure_layout': cur, 'fix_proposal': {'figure_layout': diff}}).hasPendingFigureProposal, isTrue);
      expect(
        _item({
          'pb_figure_layout': cur,
          'fix_proposal': {
            'figure_layout': same,
            'figure_crops': [
              {'figure_index': 2, 'bbox_1k': [0, 0, 10, 10], 'reason': 'missing'},
            ],
          },
        }).hasPendingFigureProposal,
        isTrue,
      );
      expect(
        _item({
          'pb_figure_layout': cur,
          'fix_proposal': {'figure_layout': diff, 'applied_at': '2026-11-03T02:00:00Z'},
        }).hasPendingFigureProposal,
        isFalse,
      );
    });

    test('원본 대조 결과: 승인 후 차이·재대조 대상·그림 크기·2단계 판정 대체', () {
      final approvedDiff = _item({
        'quality_status': 'approved',
        'render_checks': {'original_compared': true, 'flagged_after_approval': true, 'fidelity_ok': false},
      });
      expect(approvedDiff.approvedButDiffers, isTrue);
      expect(approvedDiff.needsOriginalRecheck, isFalse);
      expect(_item({'quality_status': 'approved'}).needsOriginalRecheck, isTrue);

      expect(_item({'render_checks': {'figure_size_ratio': 1.6}}).figureNeedsResize, isTrue);
      expect(_item({'render_checks': {'figure_size_ratio': 1.1}}).figureNeedsResize, isFalse);
      expect(_item({'render_checks': {'figure_size_ratio': null}}).figureNeedsResize, isFalse);

      final passed = _item({
        'render_checked_at': '2026-11-03T02:00:00Z',
        'render_checks': {
          'original_compared': true,
          'problem_ok': true,
          'fidelity_ok': true,
          'figure_position_ok': true,
          'figure_size_ratio': 1.0,
        },
      });
      expect(passed.stage2Superseded, isTrue);
      expect(passed.renderHasIssue, isFalse);

      final failed = _item({
        'render_checked_at': '2026-11-03T02:00:00Z',
        'render_checks': {'original_compared': true, 'figure_position_ok': false},
      });
      expect(failed.stage2Superseded, isFalse);
      expect(failed.renderHasIssue, isTrue);
    });

    test('needsMathResolve: 수학 일괄 규칙으로 끝나지 않는 수학 오류만 다시 푼다', () {
      // 채점 정답 = 해설 정답인데 AI 가 옛 본문으로 판단불가
      expect(
        _item({'math_status': 'issue', 'existing_answer': '×', 'solution_answer': r'$\times$', 'ai_answer': '판단불가'})
            .needsMathResolve,
        isTrue,
      );
      // 해설·AI 일치 → 해설 답 채택 규칙
      expect(
        _item({'math_status': 'issue', 'existing_answer': '3', 'solution_answer': '4', 'ai_answer': '4'}).needsMathResolve,
        isFalse,
      );
      // 채점 정답 = AI 답 → 2:1 유지 규칙
      expect(
        _item({'math_status': 'issue', 'existing_answer': '4', 'solution_answer': '3', 'ai_answer': '4'}).needsMathResolve,
        isFalse,
      );
      expect(_item({'math_status': 'approved', 'existing_answer': '×', 'ai_answer': '판단불가'}).needsMathResolve, isFalse);
      expect(_item({'math_status': 'clean'}).needsMathResolve, isFalse);
    });

    test('problemTextSignature 는 본문·공통 발문·선지·그림 수가 바뀌면 달라진다', () {
      final base = _item({'common_stem': '다음을 구하여라.'});
      expect(base.problemTextSignature, _item({'common_stem': '다음을 구하여라.'}).problemTextSignature);
      expect(base.problemTextSignature == _item({'common_stem': '다음을 구하여라.', 'stem': '7'}).problemTextSignature, isFalse);
      expect(base.problemTextSignature == _item({}).problemTextSignature, isFalse);
      expect(
        base.problemTextSignature ==
            _item({
              'common_stem': '다음을 구하여라.',
              'choices': [
                {'label': '①', 'text': '2'},
              ],
            }).problemTextSignature,
        isFalse,
      );
      expect(
        base.problemTextSignature ==
            _item({
              'common_stem': '다음을 구하여라.',
              'pb_figure_assets': [
                {'figure_index': 1, 'path': 'a'},
              ],
            }).problemTextSignature,
        isFalse,
      );
    });
  });

  test('TextbookReviewChunkImage.toJson 은 원본 이미지와 좌표를 함께 보낸다', () {
    final img = TextbookReviewChunkImage(
      original: TextbookReviewRenderedRegion(
        bytes: Uint8List.fromList([1, 2, 3]),
        widthPx: 900,
        heightPx: 300,
        region1k: const [10, 20, 30, 40],
        rawPage: 7,
      ),
    );
    final j = img.toJson();
    expect(j['original_image_base64'], base64Encode([1, 2, 3]));
    expect(j['original_image_mime'], 'image/png');
    expect(j['original_width_px'], 900);
    expect(j['original_height_px'], 300);
    expect(j['original_region_1k'], [10, 20, 30, 40]);
    expect(j['original_raw_page'], 7);
    expect(j.containsKey('set_header_image_base64'), isFalse);
    expect(img.isEmpty, isFalse);
  });
}
