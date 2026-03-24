# Problem Bank Quality Gate

HWPX 문제은행 1차의 품질 게이트를 코드 기반으로 운영하기 위한 가이드입니다.

## 1) 골든 샘플 구조 회귀

- 실행: `cd gateway && npm run quality:pb`
- 매니페스트: `gateway/quality/problem_bank/golden_manifest.json`
- 각 샘플은 `expected`(정답 구조 JSON)와 `actual`(추출 결과 JSON)을 지정합니다.
- 비교 지표:
  - `questionCountAccuracy`
  - `choiceAccuracy`
  - `equationAccuracy`
  - `figureBindingAccuracy`
  - `pdfHashMatch` (선택)

권장 샘플 구성:
- 텍스트 위주(내신형)
- 수식 밀집(수능형)
- 그림/표 포함(모의고사형)
- 보기 조합형(`①~⑤`, `ㄱㄴㄷ`, `[보기]`)

## 2) 운영 지표 게이트

- 실행: `cd gateway && npm run quality:pb:metrics`
- 최근 N일 지표(기본 7일)를 집계합니다.
- 기준 미달 시 non-zero exit code로 배포 파이프라인에서 차단할 수 있습니다.

환경변수:
- `PB_METRIC_WINDOW_DAYS` (기본 7)
- `PB_METRIC_MIN_EXTRACT_SUCCESS` (기본 0.9)
- `PB_METRIC_MIN_EXPORT_SUCCESS` (기본 0.9)
- `PB_METRIC_MAX_REVIEW_REQUIRED` (기본 0.6)

## 3) 운영 전환 권장 기준

- 추출 성공률: 95% 이상
- PDF 생성 성공률: 98% 이상
- 저신뢰 문항 검수 후 재작업률: 10% 미만
- 고정 골든 샘플셋 회귀 통과율: 100%

## 4) 체크 포인트

- 샘플셋에는 반드시 그림 포함/보기 포함/수식 복합 문항을 포함합니다.
- 레이아웃 규칙 변경 시 골든 샘플 expected를 함께 갱신합니다.
- 운영 지표는 최소 주간 단위로 추적하고 임계값은 분기별로 재평가합니다.
