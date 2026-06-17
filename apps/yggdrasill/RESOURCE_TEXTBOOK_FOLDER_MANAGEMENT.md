# 자료 > 교재 탭 — 폴더 트리 관리 정책

## 사용자 앱 (Yggdrasill, 2026-06)

교재·시험·기타 탭 좌측 **폴더 트리**는 **읽기 전용**으로 동작한다.

- 허용: 폴더 선택, 하위 폴더 펼치기/접기, 즐겨찾기 선택(폴더 목록 맨 하단), 책(파일)을 폴더로 드롭 이동
- 제거: 폴더 **추가·편집·삭제**, **롱프레스 드래그**로 형제 순서 변경·부모 이동, 스와이프 액션 패널
- 교재 탭 **책 추가·과정 편집** 버튼 제거 → 매니저 앱 `TextbookMigrationPane`에서 관리

폴더 트리 패널 너비는 `resources_screen.dart` `build()`에서 고정:

| 항목 | 값 |
|------|-----|
| 트리 패널 너비 | **220~330px** (화면 1024~1920px 구간에서 선형 보간) |
| 좌측 `Padding` | `fromLTRB(12, 12, 12, 12)` |
| 화면 기준 트리 열 총폭 | 패널 너비 + 24px |

## 향후 매니저 앱 / 백엔드

폴더 **추가·삭제·순서·계층(parent)** 는 학원 운영자가 매니저 앱에서 관리하고, 백엔드에 반영한 뒤 사용자 앱에 동기화하는 흐름을 검토 중이다.

**이미 매니저로 이관된 항목** (`apps/yggdrasill_manager/.../textbook_migration_pane.dart`):

- **책 추가** — `TextbookRegisterWizard`
- **과정 편집** — `TextbookCourseEditDialog` (`answer_key_grades`)

### 데이터

- 테이블: `resource_folders` (카테고리별 `textbook` / `exam` / `other`)
- 주요 필드: `id`, `parent_id`, `order_index`, `name`, `description`, 레이아웃(`pos_x`, `pos_y`, …)

### 앱 내 참고 구현 (UI 비활성, 로직 유지)

`lib/screens/resources/resources_screen.dart` extension `_ResourcesScreenTree`:

- `_onAddFolderWithParent` — 폴더 생성 + `_saveLayout`
- `_reorderSiblings` — 같은 부모 아래 `order_index` 재정렬
- `_moveToAsChild` — 다른 폴더의 자식으로 이동
- `_handleEditFolder` / `_FolderEditDialog` — 폴더 메타 편집
- `_handleDeleteFolder` — 폴더 삭제 확인 + `_saveLayout`

매니저 연동 시 위 로직을 API 호출로 대체하거나, 관리 전용 화면에서 재사용할 수 있다.
