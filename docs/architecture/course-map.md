# 기준 과정 탐색도 (교육과정 흐름, 매니저앱)

과정(1-1 … 기하)마다 대·중·소단원을 **나열 순서**대로 보이고, 운영자가 고쳐 저장하는 플랫폼 공유 기준이다.
예전 문항로드맵 화면에 코드로 적혀 있던 목록을 DB로 옮겨 초기 자료로 쓴다.
Think와 정한 작업 지시 "기존 과정 로드맵을 저장·수정 가능한 기준 과정 탐색도로 개편"(2026-10-23)과
운영자 선택(개념 메뉴 왼쪽 칸 + 문항로드맵 메뉴, 플랫폼 공유·최고 관리자만 수정, 지우지 않고 보관, 초기 자료 2022 개정, Preview 생략)을 따른다.

| 영역 | 코드 |
|------|------|
| 화면 | `apps/yggdrasill_manager/lib/screens/curriculum/widgets/course_map_pane.dart` (`CourseMapPane` 편집, `CourseMapSummaryPane` 읽기), 최근 변경 창 `course_change_log_dialog.dart`(§6.3), 개념 메뉴 왼쪽 칸(`curriculum_screen.dart`·`concept_workspace.dart`), 문항로드맵 메뉴(`screens/problem_roadmap/problem_roadmap_screen.dart`) |
| 상태 | `lib/services/course_map_controller.dart` (`CourseMapController.instance`, 앱 전체에 하나, 과정마다 편집본 `CourseMapDraft`와 단원별 개념 배치, 개념 줄 펼침, 합계 `courseUnitTallies`) |
| 저장 | `lib/services/course_map_service.dart`, 마이그레이션 `supabase/migrations/20261023100000_course_maps.sql`, 배치·Think 카드 `20261023120000_course_map_think_actions.sql`, 배치 기록·최근 변경 `20261024120000_course_placement_log.sql` |
| Think 카드 | Edge `supabase/functions/ai_think/course_map_tools.ts`, 앱 `lib/screens/think/think_course_map_cards.dart` (§7) |
| 시험 | `test/course_map_controller_test.dart`, `test/course_map_pane_test.dart`, `test/think_course_map_cards_test.dart`, `test/concept_workspace_test.dart`(작업 공간), `tools/db_test/test/course_maps.test.mjs`, `tools/db_test/test/course_map_think.test.mjs`, `tools/db_test/test/course_placement_log.test.mjs`, Deno `ai_think/course_map_tools_test.ts` |

## 1. 원칙

- 세 가지를 섞지 않는다. 개념 라이브러리(무엇을 정리했나) / 기준 과정 탐색도(이 문서, 과정 안 단원 흐름) / 실제 학습 경로(나중).
- **순서는 선수 관계가 아니다.** A가 B 앞에 있다고 "A가 B의 선수"로 저장하거나 보이지 않는다. 화면 머리와 목록 위에 그렇게 적는다.
- 초기 자료는 "기준 초안"이다. 공식 교육과정과 맞춰 본 자료처럼 보이지 않는다(머리 배지 "기준 초안", 설명 툴팁).
- 단원 id는 이름·순서·부모가 바뀌어도 그대로다. 이름이 같다고 합치지 않고, 번호(I, 1., (1))나 순서를 id로 쓰지 않는다.
  번호와 왼쪽 단계 숫자는 화면에서 순서로 셀 뿐 저장하지 않는다.
- 지우지 않는다. 저장된 단원을 빼면 보관(`archived_at`)하고 되살릴 수 있다. 저장 전 새 단원만 바로 없어진다.
- 학습목표·개념 배치·문항이 단원 id를 가리킬 수 있게 id를 고정했다. 2026-10-23부터 개념 배치(§6)가 단원 id를 가리킨다.
  새 연결 표를 만들지 않고 개념의 교육과정 등장 위치(`concept_appearances`)에 단원 열을 더했다.
- 기존 `curriculum`·`grade`·`chapter`·`section`(0066)과 교재 단원 구조(`textbook_metadata`)는 쓰지도 바꾸지도 않는다.
  탐색도 화면의 편집·배치는 개념 라이브러리의 본문·분류·서술·출처를 바꾸지 않는다. 개념을 고치는 것은 운영자가 승인한
  Think 카드(§7)와 기존 개념 화면뿐이다.

## 2. 저장

### 2.1 표

| 표 | 뜻 |
|----|----|
| `course_maps` | 과정. `name`(40자), `school_level`(초·중·고), `curriculum_code`(개념 등장 위치와 같은 코드, 비울 수 있음), `course_key`(교재 과정 키, 이름으로 맞추지 않음), `seed_key`(초기 자료만), `sort_order`(살아 있는 과정끼리 0부터 빈칸 없이), `version`, `archived_at` |
| `course_map_units` | 단원. `course_id`, `parent_id`(같은 과정, 한 단계 위), `depth` 1~3, `name`(80자), `sort_order`(같은 부모 안 0부터 빈칸 없이), `archived_at` |
| `course_map_revisions` | 과정을 바꿀 때마다 그 과정 전체(과정 정보 + 살아 있는 단원)를 한 줄로 남긴다. `action` = seed·create·save·restore_unit·archive·restore |

- 살아 있는 단원끼리 같은 부모 안 순서가 겹치지 않게 부분 유일 색인을 둔다. 부모가 같은 과정·살아 있음·한 단계 위인지,
  보관한 단원 아래 살아 있는 단원이 없는지는 지연 제약 트리거(`course_map_units_check`)가 거래 끝에 본다.

### 2.2 접근

- 최고 관리자(`is_superadmin()`)만 읽는다. 표에 직접 쓰는 권한은 없고(anon은 모두, authenticated는 쓰기 회수) RPC로만 바뀐다.
  RPC는 `security definer`이고 첫 줄에서 `course_map_assert_operator()`로 막는다(`course_map_forbidden`).
- 초기 자료·번호 다시 매기기 같은 안쪽 함수는 누구도 직접 부를 수 없다.

### 2.3 RPC

| RPC | 하는 일 |
|-----|---------|
| `course_maps_list()` | 살아 있는 과정(순서대로) 다음 보관한 과정. 과정마다 깊이별 살아 있는 단원 수 `counts [대, 중, 소]` |
| `course_map_get(id)` | `{course, units(위에서 아래 순서), archived(보관 묶음의 맨 위: 위 단원 경로·함께 보관 수·위 단원이 살아 있는지)}` |
| `course_map_create(name, level, code)` | 새 과정을 목록 끝에, 단원 없이 |
| `course_map_save(id, version, course, units, archive)` | 한 번에 저장한다. `units` = 살아 있을 단원 전부(위에서 아래, 목록 순서가 같은 부모 안 순서), `archive` = 이번에 보관할 저장된 단원 |
| `course_map_unit_restore(id, version, unit)` | 보관 묶음을 같은 id로 되살려 같은 부모의 끝에 둔다. 위 단원이 보관돼 있으면 막는다 |
| `course_map_archive(id, version)` / `course_map_restore(id)` | 과정 보관(남은 순서를 다시 매김) / 되살려 목록 끝에 |
| `course_maps_reorder(expected, ids)` | 화면이 본 순서(`expected`)가 지금과 다르면 `course_map_list_stale` |

`course_map_save`가 막는 것(모두 아무것도 바꾸지 않는다):

- 판이 다르면 `course_map_stale`(더 새 저장본을 덮어쓰지 않는다), 보관한 과정이면 `course_map_archived`.
- 다른 과정 단원 `course_map_unit_foreign`, 보관한 단원 `course_map_unit_archived`, 같은 id 두 번 `course_map_bad_units`,
  빈 이름·길이 초과 `course_map_bad_name`, 보관 목록과 저장 목록에 함께 있음 `course_map_unit_conflict`.
- 살아 있는 단원이 두 목록 어디에도 없음 `course_map_unit_missing`(고아·조용한 삭제 방지), 부모가 저장 목록에 없음 `course_map_bad_parent`,
  순환 `course_map_cycle`, 네 단계 이상 `course_map_too_deep`.
- 보관은 아래 단원까지 함께 한다. 단, 같은 저장에서 다른 부모로 옮겨 저장 목록에 든 아래 단원은 보관하지 않는다.
- 순서는 두 번에 나눠 다시 매긴다(먼저 큰 수로 비킨 뒤 제자리). 이름·부모·순서가 바뀐 단원만 `updated_at`이 바뀐다.

### 2.4 초기 자료

- 예전 문항로드맵 화면(`problem_roadmap_screen.dart`)에 적혀 있던 13개 과정·450개 단원을 이름·계층·순서 그대로
  `course_map_seed`로 넣는다. `seed_key = roadmap:<교재 과정 키>`, 학교급은 M으로 시작하는 키면 중, 아니면 고. 교육과정 코드는 `rev_2022`.
  과정 순서는 예전 화면 과정 선택 목록 순서다.
- `seed_key`가 이미 있는 과정은 통째로 건너뛴다. 마이그레이션을 다시 실행해도 겹치거나 운영자가 고친 내용을 덮지 않는다.
  화면은 열 때 초기 자료를 다시 쓰지 않는다.
- 예전 화면 목록은 지웠다. 읽기에 실패해도 코드에 적힌 목록으로 대신 보이지 않는다.
- 원본에서 의심스러운 곳(고치지 않고 그대로 넣음, 운영자 확인 필요):
  - 공통수학1 "방정식 x^n=1의 허근" — 교과서 표기는 x^3=1이다.
  - 기하 이차곡선, 3-2 삼각비: 대·중·소에 같은 이름이 겹친다.
  - 예전 화면 안 두 과정 순서 목록이 서로 달랐다(미적분2 ↔ 확률과 통계 자리). 초기 자료는 과정 선택 목록 순서를 따랐다.

## 3. 화면

### 3.1 자리

- 개념 메뉴 왼쪽 칸(`concept-library.md` §2.1). 흐름 중심이면 편집(`CourseMapPane`), 결과 중심이면 읽기만 하는 요약(`CourseMapSummaryPane`, "크게 보기").
  좁으면 "교육과정 흐름" 칸.
- 문항로드맵 메뉴도 같은 `CourseMapPane`을 크게 연다. 같은 컨트롤러라 편집본·선택·펼침을 함께 쓴다.

### 3.2 구성

- 머리: "교육과정 흐름", "기준 초안" 배지, 저장 안 한 변경이 있으면 "저장 안 됨 N", 목록 다시 읽기, 과정 추가.
- 과정 줄: 과정 칩(32 높이, 고르면 강조색, 저장 안 한 편집이 있으면 점), 과정 관리 메뉴(추가·앞으로·뒤로·보관·보관한 과정).
- 목록: 위 안내("나열 순서(선수 관계 아님)…"), 모두 펼치기/접기, 대단원 추가. 행 36 높이, 왼쪽 56 폭 레일
  (세로선 `kThinkBorder`, 맨 아래 단원은 채운 점 `kThinkAccent`과 단계 숫자, 위 단원은 빈 점과 범위 "1–3"),
  깊이마다 16 들여쓰기, 접기 화살표, 번호(대 I·II, 중 1., 소 (1)), 이름, 배지(새 단원 / 자리 바뀜 / 이름 바뀜).
- 옆 칸(320 폭, 760보다 좁으면 아래): 선택한 단원(이름, 위로·아래로(같은 부모 안), 옮기기, 뒤에 추가, 아래에 추가, 보관/빼기),
  과정 정보(이름, 학교급, 교육과정, 교재 과정 키, 판·저장 시각), 보관한 단원(되살리기).
- 옮기기 창: 같은 과정 단원만 보인다. 자기와 자기 아래는 목록에 없고, 세 단계를 넘는 자리는 흐리게 두고 눌러도 닫히지 않는다(이유 툴팁).
- 보관: 저장된 단원이면 "아래 단원 N개"와 "지우지 않음, 되살릴 수 있음"을 묻는다. 저장 전 새 단원만이면 묻지 않고 뺀다.
- 저장 줄: "저장하는 중…" / "저장 안 한 변경 N곳 · 저장하면 단원 N개 보관" / "저장됨 · vN · 시각", 되돌리기(묻고), 저장.

### 3.3 저장 상태

- 편집본은 과정마다 컨트롤러에 남는다. 다른 과정·다른 메뉴에 다녀와도 선택·펼침·입력이 남는다(과정 칩의 점, 머리 배지로 알린다).
- 저장 안 한 편집이 있는 동안에만 창 닫기를 붙잡는다(`main.dart` `MainScreen`, `windowManager.setPreventClose`).
  창을 닫거나 로그아웃하려 하면 편집이 있는 과정 이름을 보이고 "버리고 계속"을 묻는다(`confirmDiscardCourseMapEdits`).
  편집이 없으면 묻지 않고 예전처럼 닫힌다.
- 저장은 저장 단추로만 한다. 저장하는 동안에는 편집을 받지 않는다.
- 실패하면 편집본을 그대로 두고 "저장하지 못했습니다: …"를 보인다. 성공 알림을 띄우지 않는다.
  판이 달라 막혔거나 빠진 단원이 있으면 "최신 저장본 불러오기(지금 편집 버림)"를 묻고 한다.
- 보관한 단원 되살리기와 과정 보관은 저장 안 한 편집이 있으면 막는다(바로 저장되어 판이 바뀌기 때문).
- 목록·과정을 읽지 못하면 오류와 다시 읽기만 보인다. DB에 아직 표가 없으면(`not_ready`) 마이그레이션 반영 전이라고 알린다.

## 4. 반영

- 운영 DB: 마이그레이션 `20261023100000_course_maps.sql`, 배치·Think 카드 `20261023120000_course_map_think_actions.sql`(둘 다 2026-10-23 반영).
- Edge: Think 카드(§7)용 `ai_think`를 마이그레이션 뒤에 배포했다(2026-10-23).
- 앱: 매니저앱을 다시 빌드한다. 배치 마이그레이션 전에는 단원 칸에 "DB에 개념 배치 기능이 아직 반영되지 않았습니다"가 보이고,
  개념 상세의 등장 위치는 예전 열로 읽는다. 개념 라이브러리·Think 대화는 그대로 쓴다.
- 배포 순서가 어긋나면 Think 카드 도구가 숨는다(기능 `course_map_actions`, `ai-think-actions.md` §7.1).
- 배치 기록·최근 변경(§6.3): 마이그레이션 `20261024120000_course_placement_log.sql`(2026-10-24 반영). Edge 배포는 없다(`course_think_action_apply`만
  같은 내용에 카드 id 표시를 더해 다시 정의). 반영 전에는 최근 변경 창에 "DB에 변경 기록 기능이 아직 반영되지 않았습니다"만 보이고,
  흐름 목록의 개념 줄·합계는 기존 배치 읽기만 써서 그대로 된다.

## 5. 이번에 하지 않은 것

학습목표, 서술 고르기, 선수 관계 분석, 강사별 과정, 교재 목차 자동 맞춤, PDF/VLM, 문항 연결, 학생 상태,
승인 없는 AI 순서 제안·일괄 재분류. 배치 미리보기 화면(Preview)은 운영자가 생략을 골랐다.

## 6. 개념 배치

2026-10-23 운영자 결정: 라이브러리 개념을 기준 과정의 단원에 놓는다. 저장은 등장 위치를 넓혀서, 화면은 단원별 목록과 직접 넣기·빼기·순서·옮기기.

### 6.1 저장

- `concept_appearances`에 `course_unit_id`(기준 단원), `unit_sort_order`(단원 안 순서), `origin`(`owner` 운영자 직접 / `ai` 승인한 Think 카드),
  `note`(Think 카드 근거)를 더했다. 단원이 있는 줄을 "배치"라 부른다.
- 같은 개념은 한 단원에 한 번(부분 유일 색인). 다른 단원·다른 과정에는 여러 번 놓일 수 있다. 글로 적은 등장 위치는 그대로다.
- 배치 줄의 교육과정 판·학교급·과정 이름·단원 경로는 탐색도에서 채우고(`concept_appearance_unit_fill`), 과정 판이 오를 때마다 다시 맞춘다
  (`course_map_sync_appearances`). 그래서 개념 상세 "교육과정 등장 위치"에 탐색도 경로가 보인다.
- 배치 줄은 아래 RPC로만 넣고 옮긴다(트리거가 `ygg.course_placement`를 켠 동안만 허용, 아니면 `course_placement_use_rpc`).
  빼기는 RPC나 기존 등장 위치 빼기(줄 삭제) 모두 된다. 순서 빈칸은 다음 순서 바꾸기·넣기에서 메운다.
- 단원·과정을 보관해도 배치를 지우지 않는다. 목록·수에서만 빠지고, 되살리면 다시 보인다.

| RPC | 하는 일 |
|-----|---------|
| `course_map_placements(course)` | 과정의 살아 있는 단원에 놓인 개념(단원 → 순서). 이름·유형·출처 수·origin·note |
| `concept_placement_overview()` | 전체 개념 수, 살아 있는 과정에 한 번이라도 놓인 개념 수, 과정별 배치 수 |
| `course_placement_add(unit, concepts)` | 단원 끝에 1~100개. 이미 있으면 `course_placement_exists`(아무것도 넣지 않음) |
| `course_placement_remove(id)` / `course_placement_move(id, unit)` | 빼기 / 같은 과정 다른 단원 끝으로. 옮기면 `origin = owner`, Think 근거는 지운다 |
| `course_placement_reorder(unit, ids)` | `ids`는 지금 그 단원의 배치 전부여야 한다(아니면 `course_placement_stale`) |

### 6.2 화면

- 흐름 행: 놓인 개념이 있으면 이름 뒤에 책 아이콘과 수(툴팁 "이 단원에 놓인 개념 N개 · 눌러서 보기"). 수를 누르면 그 단원 바로 아래에
  놓인 개념 줄(32 높이, 레일은 선만, 단원 번호 자리에 맞춰 유형 표시 + 이름 + Think 배치면 "Think" 배지)이 펼쳐지고 다시 누르면 접힌다.
  맨 아래 단원은 접기 화살표 자리의 화살표로도 펼친다. 요약 칸(옆 칸이 없음)은 단원 줄을 눌러도 펼친다.
  크게 보기에서 단원 줄을 누르면 지금처럼 옆 칸("이 단원의 개념")만 연다(편집은 옆 칸에서).
- 개념 줄을 누르면 개념 라이브러리에서 그 개념을 연다(`ConceptLibraryController.openConcept`, 라이브러리 중심으로 바뀜).
  문항로드맵 메뉴는 라이브러리가 없어 개념 줄은 보기만 한다.
- 목록 위 "개념 펼치기/접기": 개념이 놓인 단원을 모두 펼치고 그 위 단원도 펼친다. 모두 펼쳐져 있을 때만 "개념 접기".
  펼침은 화면 상태라 저장할 변경으로 세지 않는다(로그아웃 때 지운다).
- 대·중단원 합계: 아래 단원까지 놓인 개념이 하나라도 있으면 이름 뒤에 "개념 N · 소단원 a/b"(N은 같은 개념을 한 번만,
  b는 맨 아래 단원 수, a는 그중 개념이 놓인 곳). 목록 폭이 420보다 좁으면 책 아이콘 + "N · a/b"로 줄이고 툴팁에 풀어 쓴다.
  편집본의 지금 단원 구조로 세고, 배치를 읽지 못하면 합계·개념 줄 모두 보이지 않는다.
- 옆 칸 "이 단원의 개념 (N)": 유형 표시 + 이름 + "Think 배치"(툴팁에 근거) + "출처 N개", 위로·아래로, 더보기(다른 단원으로 옮기기 / 이 단원에서 빼기).
  넣기·빼기·순서·옮기기는 바로 저장된다(아래 "저장"과 따로). 저장 전 새 단원에는 넣지 않는다.
- "개념 넣기" 창: 이름으로 찾아(250ms 뒤, 30개까지) 여러 개 고른다. 이미 이 단원에 있으면 흐리고 "이미 있음", 같은 과정 다른 단원에 있으면 그 번호를 보인다.
- 옮기기 창: 같은 과정의 저장된 단원만. 지금 위치는 "지금 위치", 새 단원·이미 그 개념이 있는 단원은 흐리고 이유 툴팁.
- 과정 정보에 "이 과정 단원에 놓인 개념 자리 N곳 · 라이브러리 개념 X개 중 Y개가 어느 과정에든 놓임".
- 배치를 읽지 못하면 오류와 "다시 읽기"만 보이고 예전 목록·수를 보이지 않는다. 그사이 목록이 바뀌어 막히면(`stale`·`not_found`) 다시 읽는다.
- 개념 상세 등장 위치: 배치 줄은 "기준 단원" 배지(+ "Think 배치"). 빼면 탐색도의 그 단원에서도 빠진다고 묻고, 탐색도 배치를 다시 읽는다.

### 6.3 배치 기록과 최근 변경 (2026-10-24)

운영자 결정: 배치 결과를 흐름 목록에서 보고(§6.2), 최근 변경은 따로 연 창에서 기록처럼 확인만 한다. 기록은 새 표로 남기고,
범위는 배치와 개념 본문·서술 고친 기록이다. Preview는 생략했다.

- `course_placement_log`: `concept_appearances` 트리거(`course_placement_log_write`)가 배치 놓기(`add`)·옮기기(`move`)·빼기(`remove`)를
  어느 길로 하든 남긴다(직접 RPC, Think 카드, 개념 상세의 등장 위치 빼기). 순서 바꾸기·번호 다시 매기기·과정 저장 때 경로 맞추기는 남기지 않는다.
  개념 이름·과정 이름·단원 경로(옮기면 전후)는 그때 값을 적어 둔다. 개념·단원에 FK를 걸지 않아 개념 지우기 보호(`concept-library.md` §4.4)를
  막지 않고, 지운 개념도 적어 둔 이름으로 보인다.
- 누가: `origin` = `owner`(직접) / `ai`(승인한 Think 카드). `course_think_action_apply`가 카드를 반영하는 동안 거래 안 설정
  `ygg.think_action_id`에 카드 id를 두어, 카드로 뺀 배치도 `ai`와 카드 id(`action_id`)로 남는다. 놓기·옮기기의 근거는 `note`.
- 표는 아무도 직접 읽거나 쓰지 않는다. `course_recent_changes(kinds, before_at, before_key, limit)`(최고 관리자, 읽기만)로 본다.
  네 가지를 시각 새것부터 섞는다: 배치 기록, 기록을 시작하기 전에 놓인 배치(놓기 기록이 없는 배치 줄, `before_log` — 놓은 시각과 지금 위치만),
  개념 본문 고친 기록(`concept_content_revisions`, 이름 전후·본문 고침·바로 고침/수정안 확정·쓴 쪽), 서술 확정 기록(`concept_statement_revisions`, 제목·판·메모).
  `kinds`로 거른다(placement·content·statement, 그 밖은 `course_changes_bad_kinds`). 더 보기는 마지막 줄의 시각과 키로 이어 읽는다(1~200줄, 기본 60).
  기존 자료를 옮기거나 채워 넣지 않는다.
- 창(`course_change_log_dialog.dart`): 흐름 칸 머리(크게 보기·요약 둘 다)의 `history` 단추 "최근 변경 기록". 거르기 "배치"·"본문·서술",
  날짜 머리(오늘·어제·날짜), 줄마다 시각 + 할 일(놓음·옮김·뺌·이름/본문 고침·서술 확정) + 누가(Think 카드·직접·수정안 확정) + "기록 시작 전" +
  개념 이름(누르면 창을 닫고 라이브러리에서 연다) + 과정·단원 경로(옮기면 전 → 후) + 근거·메모. 읽기만 하고 되돌리기는 없다.
  처음부터 다시 읽을 때(열기·거르기·다시 읽기)는 보이던 줄을 먼저 비워, 실패하면 오류와 "다시 읽기"만 보인다(반영 전이면 그 안내).
  더 보기에 실패하면 이미 읽은 줄 아래에 오류와 "다시 읽기"를 보인다.

## 7. Think 카드

2026-10-23 운영자 결정: Think가 대화에서 과정·단원·배치·개념을 고치자고 **제안**하고, 운영자가 카드에서 승인한 것만 바뀐다.

| 항목 | 결정 |
|------|------|
| 범위 | 배치(놓기·옮기기·빼기·순서), 단원(더하기·이름·옮기기·보관), 과정(만들기·정보·보관·되살리기), 개념(만들기·고치기·서술 고치기·지우기) |
| 후보 | 모든 개념. 출처가 없거나 출처로 정할 수 없으면 "출처 없이 판단"으로 표시한다 |
| 카드 | 배치는 한 과정·50개까지 한 장. 항목마다 빼기·단원 바꾸기, "고른 것 승인" |
| 지우기 | 붙은 것(출처·서술·등장 위치·배치·관계·검토·기준·주제 묶음·수정안·유형 연결·본문 고친 기록·열린 초안의 대상 등)이 하나도 없는 개념만. 있으면 카드에 무엇이 붙었는지 보이고 막는다. 기준과 DB 보호는 `concept-library.md` §4.4(2026-10-23) |
| 본문·서술 | 승인하면 바로 확정. 고친 기록에 "Think 카드 승인: 이유" |
| Preview | 생략 |

### 7.1 흐름

```
Think 읽기 도구: get_course_maps · list_placement_candidates(course_sources / unplaced / no_source / search) · get_concept_for_edit
Think 제안 도구: propose_course_map_change · propose_course_create · propose_concept_placement · propose_concept_change
  → course_think_action_propose(대화, 종류, payload): 서버가 검증하고 미리보기를 계산해 ai_actions 1행
     항목 오류는 course_placement_bad_item:<번호>:<이유> / concept_think_bad_item:<번호>:<이유>로 돌려준다(Think가 고쳐 다시 냄)
운영자: 카드에서 항목 빼기·단원 바꾸기 → course_think_action_apply(id, {skip: [i], units: {"i": 단원 id}})
```

- 한 답변 카드 수: 배치 4장, 검토 기록 2장, 관계 2장, 나머지 1장. 같은 대화에서 같은 과정의 탐색도 고치기만 새 제안이 앞 제안을 대체하고, 나머지는 쌓인다(앱도 같은 규칙).
- 범위별 개념 검토 기록 카드(`propose_concept_review` → `concept_review_record`)도 같은 길로 들어가고 같은 항목 카드로 승인한다
  (`concept_review_bad_item:<번호>:<이유>`). 기록만 남기고 개념은 바꾸지 않는다. 규칙은 `concept-library.md` §4.5.
- 개념 관계 카드(`propose_concept_relation_change` → `concept_relation_change`)도 같은 길이다(`concept_relation_bad_item:<번호>:<이유>`).
  빼기는 관계만 지운다. 규칙은 `concept-library.md` §4.6.
- 탐색도 고치기·새 과정은 통째로 되거나 안 된다. 탐색도 고치기는 제안 때 판(`base_version`)이 다르면 `course_map_stale`로 막힌다.
- 배치·개념·검토 기록 카드는 항목마다 따로 반영한다. 실패한 항목은 결과에 이유가 남고 나머지는 반영된다. 고른 항목이 모두 실패하면
  내용은 되돌리고 카드는 `proposed`로 남긴다. `result.attempt_failed`와 `error`(`course_think_all_failed:…`)에 그 시도를 저장한다.
  원인을 고치면 같은 카드를 다시 승인하고, 성공하면 `error`를 비운다. 고른 것이 없으면 `course_think_nothing_selected`로 예외가 나고 결과는 저장하지 않는다.
  관계 카드의 전체 실패는 예전처럼 예외로 롤백한다.
- 배치 근거: `basis source`(출처의 학년이 그 과정 키로 읽힐 때만, evidence에 책·학년·책 단원) / `judgment`(그 밖, 판단 이유).
- 개념 만들기는 이미 있는 유형만 쓰고, 없는 폴더 칸은 개념 초안 확정과 같은 방식으로 만든다. 같은 이름 개념이 있으면 카드에 알리기만 한다.
- 고치기·서술 고치기는 제안 때 내용과 다르면(`concept_think_stale`, `concept_statement_stale`), 확정 전 수정안이 있으면(`concept_content_draft_pending`) 막힌다.
- 지운 개념의 이름·본문·폴더·유형은 그 카드 결과(`result.items[].deleted`)에 남는다.

### 7.2 카드 화면 (`CourseThinkActionCard`)

- 머리: 종류 이름 + "제안", "승인 대기". 제목 한 줄과 수 요약(넣기 N · 옮기기 N …), 배치면 "출처 없이 판단 N", 개념이면 지울 수 없는 수.
- 항목 상자: 체크(빼기), 번호, 할 일 배지(넣기·만들기 강조색, 옮기기·고치기 링크색, 빼기·지우기 오류색, 순서 보조색), 이름, 유형,
  근거 배지("교재 출처" / "출처 없이 판단"), 경로(`→ 단원`, `전 → 후`), 근거, 이미 놓인 곳. 막힌 항목은 오류색 테두리와 "지울 수 없음"이고 처음부터 빠져 있다.
- 배치 "단원 바꾸기": 제안 때 서버가 준 살아 있는 단원 목록에서 찾아 고른다("Think 제안"·"고름" 배지), "제안대로"로 되돌린다.
- 개념 고치기: 폴더(끝 몇 단계가 새 폴더인지), 놓을 단원, 같은 이름 안내, 본문은 접어 두고 수식으로 본다. 서술은 바뀐 칸만 전 → 후.
- 탐색도 고치기: 바꿀 것 목록, 보관하는 단원에 놓인 개념 자리 수, 이 과정에 저장 안 한 편집이 있으면 그 편집은 저장 때 막힌다는 안내.
- 검토 기록: 결과별 수, 항목마다 범위 배지(링크색)·이름·결과 배지(문제 있음·병합 필요 오류색, 비교 더 필요 강조색, 확인 못 함 흐린색, 문제 못 찾음 보조색),
  유형·폴더, 확인한 것·찾은 것·근거·확인 못 한 것·더 할 일(160자 넘으면 접음), 비교한 개념·더 비교할 개념, 앞선 기록(결과·날짜·그 뒤 바뀜),
  같은 개념·범위의 다른 대기 카드 수. 승인 안내에 "문제 못 찾음은 검증이 아님"과 "기록이 붙으면 지울 수 없음". 승인 뒤 기록한 개념을 개념 탭이 다시 읽는다.
- 버튼: "고른 것 승인 (n)"(항목 카드) 또는 "승인", "모두 고르기/모두 빼기", "거절". 승인 뒤 한 줄 "반영 n개 · 못 함 n개 · 뺌 n개"와 못 한 항목의 이유.
- 승인 뒤 탐색도(편집 안 한 과정은 새로 읽고, 편집 중인 과정은 배치만)와 개념 라이브러리(트리, 열린 개념)를 다시 읽는다.
