# Yggdrasill Design Preview

본앱과 완전히 분리된 UI 목업/컨펌 전용 Flutter 앱입니다.

## 실행

```powershell
cd apps\yggdrasill_design_preview
flutter pub get
flutter run -d windows
```

본앱과 동시에 실행:

```powershell
cd apps\yggdrasill
flutter run -d windows
```

Preview 앱은 별도 `build/` 폴더를 사용하므로 Windows DLL 잠금 충돌을 피합니다.

## 구조

- 학습앱 Preview 소스: `../yggdrasill/lib/screens/design_preview/`
- 매니저앱 Preview 소스: `../yggdrasill_manager/lib/screens/design_preview/`
- 이 앱은 두 패키지를 `path` 의존성으로 가져와 Preview Hub에서 선택 표시합니다.

## 규칙

- 실제 기능, DB, Supabase 연결 금지
- mock 데이터만 사용
- 컨펌 전 프로덕션 `*_screen.dart` 수정 금지
- 상세 규칙: `../../docs/design-system.md`
