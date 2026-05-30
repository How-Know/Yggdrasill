# Design Preview (매니저앱 `yggdrasill_manager`)

UI 변경은 **이 트리 아래 Preview**에서 먼저 작업한다.

- 규칙: [`docs/design-system.md`](../../../../../docs/design-system.md) §7–§8
- mock 데이터만 / Supabase·SharedPreferences 저장 금지
- 컨펌 전 `screens/management/management_screen.dart` 수정 금지

## 폴더 구조

```
design_preview/
  design_preview_hub_screen.dart
  yggdrasill_manager/
    settings/
      management_settings_preview_screen.dart
```

**학습앱·M5** Preview는 별도 패키지:  
`apps/yggdrasill/lib/screens/design_preview/` (`yggdrasill/`, `m5/`)

## 별도 창으로 띄우기 (실사용 앱과 동시 실행)

터미널 **1** — 본앱:

```powershell
cd apps\yggdrasill_manager
flutter run -d windows
```

터미널 **2** — Preview 전용:

```powershell
cd apps\yggdrasill_manager
flutter run -d windows -t lib/main_design_preview.dart
```
