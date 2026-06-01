# Design Preview (학습앱 `yggdrasill`)

UI 변경은 **프로덕션 화면이 아니라 이 트리 아래 Preview**에서 먼저 작업한다.

- 규칙: [`docs/design-system.md`](../../../../../docs/design-system.md) §7
- mock 데이터만 / Provider·API·비즈니스 `onTap` 연결 금지
- 컨펌 전 `screens/settings/settings_screen.dart` 등 프로덕션 파일 수정 금지

## 폴더 구조 (앱·도메인 분리)

```
design_preview/
  design_preview_hub_screen.dart     # Preview 목록
  yggdrasill/                        # 학습앱 화면 목업/시안
    settings/
      settings_preview_screen.dart   # 컨셉 목업
  m5/                                # M5 기기·바인딩 관련 UI (학습앱 내 M5 흐름)
    README.md
```

## 설정 화면 Preview 원칙

- **설정 - 실제 기준선**: `screens/settings/settings_screen.dart`를 그대로 띄운다.
  미세 조정은 이 화면을 기준으로 한다.
- **설정 - 컨셉 목업**: mock 데이터 기반 단순화 시안이다. 실제 화면과 다를 수 있으므로
  바로 반영 기준으로 쓰지 않는다.

**매니저앱** Preview는 별도 패키지:  
`apps/yggdrasill_manager/lib/screens/design_preview/`

## 별도 창으로 띄우기 (완전 분리)

터미널 **1** — 평소처럼 본앱:

```powershell
cd apps\yggdrasill
flutter run -d windows
```

터미널 **2** — 디자인 Preview 전용 앱:

```powershell
cd apps\yggdrasill_design_preview
flutter run -d windows
```

두 창은 **서로 다른 Flutter 프로젝트**라 Windows `build/windows/.../Debug`
산출물이 충돌하지 않습니다. Preview 쪽만 수정·저장하면 Preview 앱만 갱신됩니다.

## 구조

이 폴더는 Preview **소스**를 보관하고, 실행은
`apps/yggdrasill_design_preview`가 담당합니다.
