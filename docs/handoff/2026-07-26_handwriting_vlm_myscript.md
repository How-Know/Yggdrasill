# 인수인계: 필기 인식 개선 · VLM 폴백 · MyScript PoC 계획

> 2026-07-26, Windows 세션에서 작성. 맥에서 이어서 작업하는 AI 에게 전달하는
> 문서다. 이 문서만 읽으면 배경·현재 상태·다음 할 일을 모두 파악할 수 있게 썼다.

## 1. 배경 (무슨 문제였나)

학생용 아이패드 앱(`apps/yggdrasill_student`)의 교재 풀기 화면에서 학생이
Apple Pencil 로 정답을 필기하면 **ML Kit Digital Ink(en-US 텍스트 모델)** 로
인식한다. 문제:

- **긴 다항식·문자 답을 거의 인식 못 함.** en-US 는 영어 텍스트 모델이라
  `3x^2+2x-1` 같은 수식을 영단어처럼 읽는다. ML Kit 에는 수식 전용 모델이
  없어서 모델 교체로는 해결 불가. (매니저앱 문제은행 「필기」 탭의 신고
  #1~#3 이 전부 이 사례)
- 인식 실패 시 학생이 신고하는 기능이 있는데, 초기 구현은 모드 전환/문항
  이동 시 필기 데이터가 유실되는 등 문제가 있었다 (해결 완료, 아래 참조).

장기 방향으로 **MyScript iink SDK**(온디바이스 수식 인식, GoodNotes 급)
도입을 검토 중이고, 그 전 단계로 **VLM(Gemini) 2차 인식 폴백**을 구현했다.

## 2. 완료된 작업 (전부 배포/적용까지 끝남)

### 2-1. 필기 신고 파이프라인 개선
- `apps/yggdrasill_student/lib/services/handwriting_candidates.dart` —
  ML Kit 후보 재랭킹. 답 유형(objective=보기번호 1~5 / subjective=수식)을
  알고 있으므로 답으로 그럴듯한 후보를 고르고, `l→1, S→5` 같은 혼동 글자를
  보정한다. `pickPlausibleHandwritingCandidate` 는 그럴듯한 후보가 없으면
  **null** 을 돌려주고, 이것이 VLM 폴백의 트리거다.
- `apps/yggdrasill_student/lib/widgets/pencil_input_pad.dart` —
  인식 때마다 스냅샷(획 좌표·타이밍·압력·후보·인식 결과)을 발행하고,
  solve screen 이 `cropId` 별로 보관해 모드 전환/문항 이동에도 신고 데이터가
  유실되지 않는다.
- 매니저앱 `apps/yggdrasill_manager/lib/screens/problem_bank/handwriting_sample_render.dart` —
  신고된 획 데이터를 화면·AI 판단용 PNG 로 동일 페인터로 렌더 (화면 캡처
  방식 폐기). 샘플에 `#N` 고정 번호(sample_no) 부여.

### 2-2. VLM 2차 인식 폴백 (이번 세션 신규)
동작 흐름: 온디바이스 인식 → 후보 전부가 답 형태가 아니거나 인식 실패
→ 획을 흰 배경 PNG 로 오프스크린 렌더 → Edge Function
`student_handwriting_recognize` → Gemini 가 선형 표기(`3x^2+2x-1`)로 읽음
→ 정답 칸에 반영. 실패/12초 타임아웃 시 기존 동작으로 폴백.

- `supabase/functions/student_handwriting_recognize/index.ts` (신규, **배포됨**)
  - 학생 인증(student_app_accounts) 필수. `GEMINI_API_KEY` 사용,
    모델은 `GEMINI_HANDWRITING_MODEL > GEMINI_MODEL > 기본값`.
- `apps/yggdrasill_student/lib/services/handwriting_ink_png.dart` (신규) —
  획 → PNG 렌더 (긴 변 1024px).
- `pencil_input_pad.dart` 에 `remoteRecognizer` 파라미터,
  `textbook_solve_screen.dart` 에서 배선, `textbook_api.dart` 에
  `recognizeHandwriting()` 추가.
- 폴백 사용 시 스냅샷에 `used_remote_fallback: true` 가 남는다 (필기 탭에서
  구분 가능).
- 테스트: `test/handwriting_candidates_test.dart`,
  `test/handwriting_ink_png_test.dart` — 21건 통과.

### 2-3. 수학적 동치 채점 로그 + 매니저 「채점」 탭
채점 Edge Function(`student_textbook_grade`)에는 이미 3단 판정이 있었다:
① 결정적 동치(정규화+수치 샘플링+목록/단위/부등식) ② AI 단위 판정
③ AI 표현 동치 판정. 판정 이벤트가 어디에도 안 쌓이던 것을:

- `supabase/migrations/20260726120000_grading_equiv_logs.sql` (**적용됨**) —
  `student_grading_equiv_logs` 테이블. "동치 판정이 개입한 채점"만 기록
  (완전 일치 정답·단순 오답은 기록 안 함). `log_no` 고정 번호,
  `staff_grading_equiv_logs` / `staff_review_grading_equiv_log` RPC.
- `supabase/functions/student_textbook_grade/index.ts` (**배포됨**) —
  `logEquivCase` 로 form_differs / AI 판정 케이스를 upsert.
- 매니저앱 문제은행에 5번째 탭 「채점」
  (`apps/yggdrasill_manager/lib/screens/problem_bank/grading_equiv_tab.dart`) —
  교사가 「동치 맞음/동치 아님」을 확정. 이 「판정+교사 교정」 쌍이 향후
  자체 서술형 채점 AI 의 학습 데이터가 된다.

### 2-4. 기타 (같은 기간 작업)
- 학생앱 과제 동기화를 폴링 → **Supabase Realtime + 1.2초 폴백 폴**로 전환
  (`homework_session.dart`, 마이그레이션 `20260725233000` **적용됨**).
- 과제 카드/검색바 바운스 애니메이션 등 UI 다듬기.

### 2-5. 운영 상태 요약
- 마이그레이션 3개(`20260725233000`, `20260726110000`, `20260726120000`)
  **모두 원격 DB 적용 완료**.
- Edge Function `student_textbook_grade`, `student_handwriting_recognize`
  **모두 배포 완료** (프로젝트 jkanrdxaidumlvpntudy).
- 앱은 재빌드 필요 (학생앱·매니저앱 둘 다 코드 변경 있음).

## 3. 맥에서 할 일 — MyScript iink PoC

Windows 에서는 iOS 네이티브 빌드가 불가능해 이 부분만 남았다.

### 배경 합의 사항 (사용자와 논의된 결론)
- MyScript iink SDK 는 수식 필기 인식 최고 수준, 온디바이스 실시간.
- 비용: 개발/평가/내부 사용은 무료 티어로 가능. 상용 배포는 견적 계약
  필요하지만 **8기기 내부 사용 규모면 무료로 즉시 도입 가능**하다고 안내함.
  MyScript 개발자 계정 + 인증서(라이선스 키) 발급은 **사용자(원장님) 작업**.
- 방식: **오프스크린 에디터** 접근을 쓴다. 즉 지금의 Flutter 필기 캔버스
  (`PencilInputPad`)와 필기감은 그대로 유지하고, 획 좌표만 플랫폼 채널로
  네이티브에 넘겨 MyScript 의 off-screen editor(Math part)로 인식 결과만
  받아온다. MyScript 의 `EditorView`(네이티브 임베드 UI)는 쓰지 않기로 함 —
  단, PoC 단계에서 비교용 데모로 띄워보는 것은 가치 있음.

### PoC 순서 (제안)
1. 사용자에게 MyScript 인증서(`.c` 파일 형태 키) 준비됐는지 확인.
2. `apps/yggdrasill_student/ios` 에 CocoaPods 로 iink SDK 추가,
   Swift 쪽에 off-screen editor 래퍼 (Math part, 결과는 LaTeX 또는
   MathML → 앱의 선형 표기로 변환).
3. Flutter 플랫폼 채널 (`MethodChannel`) — 입력: 획 배열
   (`pencil_input_pad.dart` 의 `_strokes` 와 동일한 x/y/t 형식),
   출력: 인식 문자열. 기존 `candidateSelector`/`remoteRecognizer` 구조에
   "엔진 교체" 지점이 이미 있으니 `_recognize` 의 ML Kit 호출부만
   조건 분기하면 된다.
4. **벤치마크**: 매니저앱 필기 탭(`student_handwriting_samples`)에 실제
   신고 획 데이터가 쌓여 있다. 같은 획을 ML Kit vs VLM 폴백 vs MyScript
   에 재생해 정확도를 비교하고, 결과에 따라 기본 엔진 교체 여부 결정.
5. VLM 폴백이 이미 안전망이므로 MyScript 는 검증 후 천천히 도입해도 된다.

### 주의점
- `PencilInputPad` 스냅샷 형식(`canvas_width/height`, `strokes[].x/y/t/p`)은
  신고·매니저 렌더·테스트 픽스처가 모두 공유하는 계약이다. 바꾸면
  `handwriting_sample_render.dart` 와 테스트도 같이 바꿔야 한다.
- 폴백 트리거 한계: `3x^2` 를 `3x2` 로 읽는 경우처럼 "답 형태로는 그럴듯한
  오인식"은 클라이언트가 감지 못 한다 (정답은 서버만 안다). MyScript 도입의
  핵심 동기가 이것.
- Edge Function 배포는 `supabase functions deploy <이름>`, 마이그레이션은
  `supabase db push` (프로젝트 링크 완료 상태).

## 4. 참고 파일 목록 (빠른 진입점)

| 영역 | 파일 |
|---|---|
| 필기 패드·인식 | `apps/yggdrasill_student/lib/widgets/pencil_input_pad.dart` |
| 후보 재랭킹·폴백 트리거 | `apps/yggdrasill_student/lib/services/handwriting_candidates.dart` |
| PNG 렌더(학생) | `apps/yggdrasill_student/lib/services/handwriting_ink_png.dart` |
| VLM 폴백 함수 | `supabase/functions/student_handwriting_recognize/index.ts` |
| 채점 함수·동치 로깅 | `supabase/functions/student_textbook_grade/index.ts`, `grading.ts` |
| 필기 탭(매니저) | `apps/yggdrasill_manager/lib/screens/problem_bank/handwriting_review_tab.dart` |
| 채점 탭(매니저) | `apps/yggdrasill_manager/lib/screens/problem_bank/grading_equiv_tab.dart` |
| 획 렌더(매니저) | `apps/yggdrasill_manager/lib/screens/problem_bank/handwriting_sample_render.dart` |
