# Design Preview (학습앱 `yggdrasill`)

UI 변경은 **프로덕션 화면이 아니라 이 트리 아래 Preview**에서 먼저 작업한다.

- 규칙: [`docs/design-system.md`](../../../../../docs/design-system.md) §7
- mock 데이터만 / Provider·API·비즈니스 `onTap` 연결 금지
- 컨펌 전 `screens/settings/settings_screen.dart` 등 프로덕션 파일 수정 금지

## 폴더 구조 (앱·도메인 분리)

```
design_preview/
  design_preview_hub_screen.dart     # Preview 목록 (kDebugMode 진입)
  yggdrasill/                        # 학습앱 화면 목업
    settings/
      settings_preview_screen.dart
  m5/                                # M5 기기·바인딩 관련 UI (학습앱 내 M5 흐름)
    README.md
```

**매니저앱** Preview는 별도 패키지:  
`apps/yggdrasill_manager/lib/screens/design_preview/`

## 별도 창으로 띄우기 (실사용 앱과 동시 실행)

터미널 **1** — 평소처럼 본앱:

```powershell
cd apps\yggdrasill
flutter run -d windows
```

터미널 **2** — 디자인 Preview 전용 창 (Supabase/DB 없이 가벼움):

```powershell
cd apps\yggdrasill
flutter run -d windows -t lib/main_design_preview.dart
```

두 창은 **서로 다른 프로세스**라 Hot Reload도 각각 독립입니다. Preview 쪽만 수정·저장하면 Preview 창만 갱신됩니다.

## 본앱 안에서 라우트로 열기 (선택)

```dart
Navigator.of(context).pushNamed('/design-preview');
```

`kDebugMode`에서만 등록됨. 라우트: `/design-preview/yggdrasill/settings`
