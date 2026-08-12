# 맥 작업 지시서: 집합 기호 인식 (MyScript SK)

> 2026-08-12, Windows 세션에서 작성. 맥에서 iOS 빌드로 이어서 작업할 때 읽는다.
> 앞선 인수인계 문서(`2026-07-26_handwriting_vlm_myscript.md`)는 MyScript 도입
> **이전** 상태 기준이라 일부 내용이 낡았다. 필기 인식 관련해서는 이 문서가 최신이다.

## 0. 한 줄 요약

학생이 집합 `{1,2,3}` 을 필기하면 MyScript 가 이를 **연립방정식(케이스 분류)** 으로
파싱하는 문제가 있다. 오늘 Windows 에서 **앱 쪽 2개 층은 고쳤고**, 남은
**엔진 파싱 층**은 iOS 빌드가 필요해 맥 작업으로 남겨 뒀다.

## 1. 배경 — 왜 깨졌나 (3층 구조)

학생앱 필기 인식 경로는 이렇다:

```
Apple Pencil 획 (PencilInputPad)
  → [층1] MyScript iink 4.5 Math Recognizer (오프스크린 배치) → LaTeX
  → [층2] latexToLinear() → 앱 선형 표기
  → [층3] pickPlausibleHandwritingCandidate() 답 형태 판정
  → (판정 실패 시) VLM 폴백: Gemini Edge Function
```

집합 기호가 깨진 원인은 세 층 중 **셋 다**였다.

### 층1 — 엔진 문법 (❗아직 안 고침, 이번 맥 작업 대상)

MyScript 수식 문법에는 중괄호를 쓰는 규칙이 두 개 있다.

| 규칙 | 의미 | 예 |
|---|---|---|
| `fence(exp, left, right)` | 양쪽 괄호 = **집합** | `{1,2,3}` |
| `leftfence(exp, symbol)` | 왼쪽 괄호만 = **연립/케이스** | `{x+y=1 ; x−y=3` |

학생이 `{` 를 세로로 길게 쓰거나, 닫는 `}` 가 흐리거나, 원소를 세로로 나열하면
엔진이 `leftfence` 쪽이 더 그럴듯하다고 판단한다. 이게 원장님이 보신 증상이다.

**집합 기호 자체를 못 읽는 게 아니다.** MyScript 4.5 공식 지원 기호 목록에
`{ } ∈ ∉ ∪ ∩ ⊂ ⊃ ⊆ ⊇ ∅ ∀ ∃ ℕ ℤ ℚ ℝ ℂ` 가 전부 들어 있다. 순수하게 **파싱 규칙
선택**의 문제다.

### 층2 — LaTeX→선형 변환기 (✅ 오늘 고침)

`latex_linear.dart` 의 심볼 표에 집합·논리 기호가 아예 없어서, 엔진이 집합을
제대로 인식해도 결과가 뭉개졌다. 실측 기록:

| MyScript LaTeX | 수정 전 | 수정 후 |
|---|---|---|
| `A\cup B` | `AcupB` | `A∪B` |
| `2\in A` | `2inA` | `2∈A` |
| `\{x\mid x>0\}` | `{xmidx>0}` | `{x\|x>0}` |
| `\varnothing` | `varnothing` | `∅` |
| `\left\{\begin{matrix}1\\2\\3\end{matrix}\right.` | `{beginmatrix1\2\3endmatrix` | `{1,2,3}` |

### 층3 — 답 형태 판정 (✅ 오늘 고침)

`handwriting_candidates.dart` 의 허용 문자표에 `{ } ∈ ∪ ∩` 이 없고 "숫자가 최소
하나" 조건이 있어서, 완벽히 인식된 `{1,2,3}` 이나 `A∪B` 도 "답 아님"으로 판정 →
불필요하게 VLM 폴백(서버 왕복)을 탔다. 허용 문자에 집합 기호를 넣고, 근거 조건을
"숫자 **또는** 집합 기호"로 완화했다.

### 오늘 변경된 파일 (Windows, 커밋 대상)

- `apps/yggdrasill_student/lib/services/latex_linear.dart`
- `apps/yggdrasill_student/lib/services/handwriting_candidates.dart`
- `apps/yggdrasill_student/test/latex_linear_test.dart` (집합·환경 케이스 추가)
- `apps/yggdrasill_student/test/handwriting_candidates_test.dart`

`flutter test` 70건 통과, 린트 클린. **Dart 전용 변경이라 재빌드만 하면 적용된다.**

## 2. 맥에서 할 일

### 작업 A — 빌드 전 준비 (필수, 새 머신이면)

```bash
cd apps/yggdrasill_student/ios/MyScriptMath && ./fetch_iink_sdk.sh   # 500MB+, git 미포함
cd apps/yggdrasill_student/ios && pod install
```

- `ios/MyScriptMath/Classes/MyCertificate.c` 가 **발급받은 인증서**여야 한다.
  플레이스홀더(length 0)면 `MyScriptMathEngine.statusMessage` 가
  `certificate_missing` 이 되고 앱은 조용히 ML Kit 경로로 폴백한다.
  (증상: 인식은 되는데 수식 품질이 예전 그대로 → 인증서부터 의심)

### 작업 B — 오늘 수정분 실기기 검증 (30분)

아이패드에서 정답 칸에 아래를 필기하고 결과를 확인한다.

| 필기 | 기대 결과 | 이게 틀리면 |
|---|---|---|
| `{1,2,3}` (한 줄, 양쪽 중괄호) | `{1,2,3}` | 층2 회귀 |
| `A∪B` | `A∪B` | 층2 심볼 표 |
| `2∈A` | `2∈A` | 층2 심볼 표 |
| 원소를 **세로로** 나열한 집합 | `{1,2,3}` 으로 복원 | 층2 환경 파싱 |
| `{` 를 크게 쓴 집합 | 여기서 층1 문제가 드러남 | → 작업 C |

각 케이스에서 **원본 LaTeX 를 같이 확인**해야 층1/층2 구분이 된다. 필기 스냅샷의
`myscript_latex` 필드에 원본이 들어 있고, 매니저앱 문제은행 「필기」 탭에서 볼 수
있다. 신고 버튼으로 올린 뒤 확인하면 된다.

### 작업 C — 층1 해결: Math Subset Knowledge (핵심)

**결론부터: 가능하다.** `math2` 번들은 **Math Subset Knowledge(SK)** 를 지원하는데,
이건 기호뿐 아니라 **규칙(rule)까지** 화이트/블랙리스트할 수 있는 필터다.
`Math Disabled Subset` 으로 `leftfence` 계열을 막으면 중괄호가 항상
`fence`(집합)로 파싱된다.

우리 iOS SDK 헤더에 필요한 API 가 이미 있다
(`ios/MyScriptMath/Headers/iink/IINKRecognitionAssetsBuilder.h`):

- `getSupportedSymbols(resourcePath:)` — 리소스가 지원하는 기호·규칙 목록
- `compile(_ type: String, data: String)` — SK 를 온디바이스 컴파일
- `store(_ fileName: String)` — `.res` 로 저장
- `supportedRecognitionAssetsTypes` — 컴파일 가능한 자산 타입 목록

#### C-1. 먼저 실물 확인 (추측 금지)

문서에는 "symbols and rules" 라고만 되어 있고 **실제 규칙 이름 문자열은 확인이
안 됐다.** 반드시 기기에서 먼저 덤프한다.

`MyScriptMathEngine.swift` 에 진단 메서드를 추가하고 채널로 노출한다:

```swift
// MyScriptMathEngine.swift 에 추가
@objc public func dumpSupportedSymbols() -> String {
  guard let engine = prepare(),
        let confDir = Self.recognitionConfDirectory() else { return statusMessage }
  let builder = engine.createRecognitionAssetsBuilder()
  let resPath = confDir + "/../resources/math/math-sr.res"
  return (try? builder.getSupportedSymbols(resourcePath: resPath)) ?? "failed"
}
```

`AppDelegate.swift` 의 `registerMyScriptMathChannel` switch 에
`case "dumpSymbols":` 를 하나 더 붙여 Dart 에서 호출하고 출력을 파일로 저장한다.
**여기서 `leftfence` / `vlist` / `table` 이 어떤 이름으로 나오는지 확인하는 게
이번 작업의 실질적 관문이다.**

- `supportedRecognitionAssetsTypes` 도 같이 찍어서 `"Math Disabled Subset"` 이
  실제 지원 타입 문자열인지 확인한다 (문서 표기와 SDK 실물이 다를 수 있다).
- 리소스 경로는 CocoaPods 통합 방식에 따라 다를 수 있다.
  `recognitionConfDirectory()` 가 이미 번들 두 곳을 확인하는 로직을 갖고 있으니
  같은 방식으로 `resources/math/math-sr.res` 를 찾는다.

#### C-2. SK 작성·컴파일·적용

C-1 에서 확인한 실제 이름으로 블랙리스트를 만든다 (아래는 **가정**, 확인 후 수정):

```
leftfence
```

```swift
let builder = engine.createRecognitionAssetsBuilder()
try builder.compile("Math Disabled Subset", data: skText)
try builder.store(destPath + "/math-no-system.res")
```

그 다음 conf 에 리소스를 추가한다
(`ios/MyScriptMath/Resources/recognition-assets/conf/math2.conf`):

```
Name: standard
Type: Math
Configuration-Script:
 AddResource math/math-sr.res
 AddResource math/math-no-system.res
 EnableMathClusterDetector false
```

> ⚠️ 컴파일된 `.res` 는 런타임에 생성되므로 앱 번들(읽기 전용)에 못 쓴다.
> `NSTemporaryDirectory()` 나 Application Support 에 저장하고, 그 디렉터리를
> `recognizer.configuration-manager.search-path` 에 **추가**하는 방식이 필요하다.
> 현재 `prepare()` 는 경로를 하나만 넣고 있으니 배열에 두 개를 넣도록 고친다.
> 또는 conf 자체를 런타임 생성 디렉터리에 통째로 복사해 쓰는 방법도 있다.

> ⚠️ **설정은 Recognizer 생성 시점에 고정된다.** 문서상 "configuration 을 먼저
> 갱신한 뒤 recognizer 를 만들어야 하고, 이후에는 바꿀 수 없다." 현재
> `runRecognition()` 은 인식할 때마다 `createRecognizer` 를 새로 만들고 있어
> (매번 새로 생성) 이 제약은 오히려 유리하다.

#### C-3. 문항 유형별 분기 (원장님 결정 사항)

원장님 확인: **"연립방정식 답을 필기로 받을 일이 드물게 있다 → 문항 유형별로
나누는 게 안전."** 따라서 SK 를 앱 전역에 켜면 안 된다.

설계:

- `recognizeLatex` 채널 인자에 `answer_kind` (또는 `allow_system: Bool`)를 추가.
- 네이티브에서 **두 개의 configuration name** 을 준비한다.
  예: `standard`(기존, 연립 허용) / `set-only`(SK 적용).
  `engine.createRecognizer(scaleX:scaleY:type:)` 는 type 만 받으므로,
  configuration 은 엔진 configuration 의 `configuration-manager` 키로 선택해야
  한다. C-1 단계에서 conf 파일에 `Name:` 블록을 두 개 두고 전환이 되는지 확인할 것.
- Dart 쪽 배선 지점: `pencil_input_pad.dart` 의 `_myscriptStrokesPayload()` 와
  `MyScriptMath.instance.recognizeLatex(...)` 호출부. `problem.answerKind` 는
  이미 `textbook_solve_screen.dart` 에서 `candidateSelector` 로 넘기고 있으므로
  같은 값을 패드까지 전달하면 된다.

> 전환이 복잡하면 **1단계로는 전역 SK 없이** 두고, 층2 의 복원 로직
> (`{1,2,3}` 재조립)만으로 충분한지 실사용 데이터를 먼저 보는 것도 합리적이다.
> 층2 수정으로 세로 나열 집합은 이미 복원되므로, 남는 손해는 "연립으로 파싱된
> 집합의 원소 순서·구분자" 정도다.

### 작업 D — 검증

- `cd apps/yggdrasill_student && flutter test` (70건 통과가 기준선)
- 실기기에서 작업 B 표를 다시 통과시킨다.
- 벤치마크: 매니저앱 「필기」 탭에 쌓인 실제 신고 획을 재생해 ML Kit / MyScript /
  VLM 결과를 비교한다.

## 3. 개발용 화면 (네비게이션 미연결 주의)

아래 두 화면은 **어디서도 push 되지 않는다.** 쓰려면 임시로 라우트를 연결하거나
디버그 메뉴에서 직접 push 해야 한다.

| 화면 | 파일 | 용도 |
|---|---|---|
| `HandwritingBenchScreen` | `lib/screens/handwriting_bench_screen.dart` | 같은 획을 ML Kit / MyScript / VLM 에 재생해 결과 비교. MyScript 상태 배너 포함 |
| `MyScriptCanvasScreen` | `lib/screens/myscript_canvas_screen.dart` | 위: iink 네이티브 EditorView, 아래: 자체 PencilInputPad. 필기감 비교용 |

C-1 의 심볼 덤프는 `HandwritingBenchScreen` 에 버튼 하나 붙이는 게 가장 빠르다.

## 4. 파일 지도

| 역할 | 경로 |
|---|---|
| 인식 엔진 래퍼 (Swift) | `ios/MyScriptMath/Classes/MyScriptMathEngine.swift` |
| 채널 등록 | `ios/Runner/AppDelegate.swift` |
| 네이티브 에디터 호스트 | `ios/MyScriptMath/Classes/MyScriptEditorHost.swift` |
| 인식 설정 | `ios/MyScriptMath/Resources/recognition-assets/conf/math2.conf` |
| 인증서 | `ios/MyScriptMath/Classes/MyCertificate.c` |
| SDK 다운로드 | `ios/MyScriptMath/fetch_iink_sdk.sh` |
| Dart 브리지 | `lib/services/myscript_math.dart` |
| LaTeX→선형 (오늘 수정) | `lib/services/latex_linear.dart` |
| 답 형태 판정 (오늘 수정) | `lib/services/handwriting_candidates.dart` |
| 필기 패드 | `lib/widgets/pencil_input_pad.dart` |
| 정답 입력 화면 | `lib/screens/textbook_solve_screen.dart` |

## 5. 열린 질문 / 주의

- **연립 답 채점 표기.** 층2 수정으로 연립이 `{x+y=1,x-y=3}` 형태로 채점
  파이프라인에 들어간다. 문제은행에 저장된 연립 정답 표기와 다르면 동치 판정이
  어긋난다. 드문 케이스라 손대지 않았고, 실제로 발생하면 매니저앱 문제은행
  「채점」 탭 로그에 잡히므로 그때 맞추면 된다.
- **`getSupportedSymbols` 결과를 반드시 저장해 둘 것.** 규칙 이름은 SDK 버전에
  종속적이라 4.5 기준 실물 목록이 남아 있어야 이후 재현이 된다.
  덤프 결과는 이 문서에 추가하거나 `docs/handoff/` 에 별도 파일로 남긴다.
- 스냅샷 형식(`canvas_width/height`, `strokes[].x/y/t/p`, `engine`,
  `myscript_latex`)은 학생앱·매니저 렌더·테스트 픽스처가 공유하는 계약이다.
  바꾸면 `handwriting_sample_render.dart` 와 테스트도 같이 바꿔야 한다.
- VLM 폴백이 안전망으로 계속 살아 있으므로, SK 작업이 막히더라도 사용자 영향은
  제한적이다. 무리해서 밀어붙이지 말 것.

## 6. 맥 실기기 조사 결과 (2026-08-13)

iPad mini의 iink 4.5 `math-sr.res`에서 `getSupportedSymbols`와
`supportedRecognitionAssetsTypes`를 직접 덤프했다.

- 지원 자산 타입: `Math Grammar`, `Text Lexicon`, `Enabled Subset`,
  `Disabled Subset`
- 문서에서 가정했던 `Math Disabled Subset`은 실제 타입명이 아니다.
- 구조 규칙: `SqrtRule`, `FracRule`, `SlantedfracRule`, `SubscriptRule`,
  `SuperscriptRule`, `SubsuperscriptRule`, `UnderscriptRule`,
  `OverscriptRule`, `UnderoverscriptRule`, `PresuperscriptRule`,
  `TableRule`, `VopRule`
- `leftfence`, `fence`, `vlist`라는 독립 규칙 이름은 노출되지 않았다.
- `{`, `}`, `∈`, `∉`, `∪`, `∩`, `⊂`, `⊃`, `⊆`, `⊇`, `∅` 등 집합
  기호 자체는 모두 지원됨을 재확인했다.

따라서 `TableRule`을 전역 또는 set-only 설정에서 차단하면 연립·행렬뿐 아니라
세로 배치 복원까지 함께 손상할 가능성이 있다. 실제 기기에서 Windows 수정분
(층2·층3)만으로 일반 집합이 정상 인식되는 것도 확인했으므로, 현재는 SK를
적용하지 않는다. 큰 왼쪽 중괄호/닫는 중괄호 누락 오인이 실제 신고 샘플로
재현될 때 해당 획을 standard와 `TableRule` 비활성 설정으로 A/B 비교한 뒤에만
제한 적용한다.

진단 API는 재현성을 위해 유지한다.

- 네이티브: `MyScriptMathEngine.dumpRecognitionAssets()`
- 채널: `dumpRecognitionAssets`
- Dart: `MyScriptMath.dumpRecognitionAssets()`
