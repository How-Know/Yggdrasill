## Yggdrasill Windows 배포 가이드 (포터블 ZIP + 앱 내 자동 업데이트)

이 문서는 배포 때마다 복붙해서 사용할 수 있는 체크리스트/명령 모음입니다.

### 준비물
- GitHub CLI(gh) 로그인 완료: `gh auth login`
- Flutter 설치/동작
- `apps/yggdrasill/env.local.json`에 `SUPABASE_URL`, `SUPABASE_ANON_KEY` 존재

### 빠른 배포(복붙 스크립트)
아래 명령은 버전 증가 → Windows 빌드 → 포터블 ZIP 생성/업로드/공개 → 검증까지 일괄 수행합니다.

```powershell
cd apps\yggdrasill
./tools/bump_version.ps1 -SkipFirmwareVersionUpdate -SkipAppInstallerUpdate

$ver = (Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+(?:\.[0-9]+){2,3})').Matches.Groups[1].Value
$tag = "v$ver"

# 태그 생성/푸시(중요: 태그가 없으면 gh release create가 untagged 릴리스를 만들 수 있음)
if(-not (git show-ref --tags $tag 2>$null)) { git tag $tag }
git push origin $tag

# 포터블 ZIP 생성 및 업로드(필수)
gh release delete $tag -R How-Know/Yggdrasill --yes 2>$null
gh release create $tag -R How-Know/Yggdrasill -t $tag -n "Yggdrasill $tag" -d
./tools/build_msix_with_defines.ps1 -ReleaseTag $tag -PortableOnly -SkipFirmware

# 릴리스 공개 + 검증
gh release edit $tag -R How-Know/Yggdrasill --draft=false
cd tools
./verify_release.ps1 -Tag $tag -PortableOnly -SkipFirmware
```

### 안정 단계별 실행(문제 발생 시)
1) 버전 bump
```powershell
cd apps\yggdrasill
./tools/bump_version.ps1 -SkipFirmwareVersionUpdate -SkipAppInstallerUpdate
```
2) Windows 빌드 + 포터블 ZIP 생성/업로드
```powershell
$ver = (Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+(?:\.[0-9]+){2,3})').Matches.Groups[1].Value
$tag = "v$ver"
./tools/build_msix_with_defines.ps1 -ReleaseTag $tag -PortableOnly -SkipFirmware
```
3) GitHub 릴리스 생성/공개
```powershell
$ver = (Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+(?:\.[0-9]+){2,3})').Matches.Groups[1].Value
$tag = "v$ver"
if(-not (git show-ref --tags $tag 2>$null)) { git tag $tag }
git push origin $tag

gh release delete $tag -R How-Know/Yggdrasill --yes 2>$null
gh release create $tag -R How-Know/Yggdrasill -t $tag -n "Yggdrasill $tag" -d
gh release edit $tag -R How-Know/Yggdrasill --draft=false
```
4) 검증
```powershell
cd tools
./verify_release.ps1 -Tag $tag -PortableOnly -SkipFirmware
```

### 업데이트 정책(포터블 자체 업데이터)
- 앱의 "업데이트 확인" 버튼은 GitHub Releases의 `releases/latest`에서 `Yggdrasill_portable_x64.zip`을 내려받아 자동 교체/재시작합니다.
- MSIX/App Installer 기반 업데이트는 Windows 정책에 의해 쉽게 깨질 수 있어 **사용하지 않습니다.**

### 업데이트 UI 디자인 토큰(통일성)
업데이트 안내 배너/스낵바는 아래 색상 규칙을 유지합니다.
- **Primary Accent**: `#1976D2` (진행/강조/포커스)
- **Card Surface**: `#232326` (업데이트 카드/스낵바 바탕)
- **Border/Track**: `#2A2A2A` (카드 테두리/프로그레스 배경)
- 변경 위치:
  - `apps/yggdrasill/lib/main.dart` (`_GlobalStartupUpdateCard`, 업데이트 완료 스낵바)
  - `apps/yggdrasill/lib/services/update_service.dart` (`_showSnack`)

### 재발 방지 체크포인트(ARM 실행 오류 포함)
- 빌드 산출물에 VC++ 런타임 DLL(`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`)이 포함되어야 합니다.
- `build_msix_with_defines.ps1`는 위 DLL이 누락되면 실패하도록 되어 있습니다(배포 차단).
- 릴리스 직후 `gh release view vX.Y.Z.N --json url` 결과 URL이 `/releases/tag/vX.Y.Z.N` 형태인지 확인합니다.

### 문제 해결(Troubleshooting)
- pubspec 인코딩 오류: 아래로 강제 저장
```powershell
Set-Content apps\yggdrasill\pubspec.yaml (Get-Content apps\yggdrasill\pubspec.yaml -Raw) -Encoding UTF8
```
- 릴리스 생성 오류(원라이너 실패): 위의 "안정 단계별 실행"으로 분리 실행
- "release not found": 릴리스 create가 실패한 상태 → 3)부터 재실행
- `gh release create` 출력 URL이 `untagged-...`로 보이는 경우:
  - 태그가 원격에 실제로 존재하는지부터 확인: `git push origin vX.Y.Z.N`
  - 그 다음 릴리스를 삭제/재생성 후 재확인: `gh release delete vX.Y.Z.N --yes` → `gh release create vX.Y.Z.N ...`
  - draft 생성 시 일시적으로 `untagged-...` URL이 보일 수 있으므로, 공개 후 `gh release view vX.Y.Z.N --json url`로 최종 URL을 확인합니다.
- gh CLI 미설치: https://cli.github.com 설치 후 `gh auth login`
- ARM64 장비: ARM64 ZIP이 없으면 x64 포터블 ZIP로 자동 폴백됩니다.

### M5Stack 펌웨어(OTA) 릴리스 체크리스트 (중요)
M5Stack(Core2) 펌웨어는 GitHub Releases의 `releases/latest`를 조회하여 업데이트를 판단합니다.

- **버전 표시 = 실제 펌웨어 버전**
  - 설정 화면의 버전 표시는 `FIRMWARE_VERSION`(펌웨어 내부 상수)을 그대로 사용합니다.
  - 따라서 OTA 후 재부팅했는데도 설정 화면이 구버전이면, **업데이트가 적용되지 않았거나(실패)** 혹은 **펌웨어가 버전 상수를 갱신하지 않고 빌드/배포된 것**입니다.
- **`firmware/m5stack/src/version.h` 동기화**
  - `#define FIRMWARE_VERSION "X.Y.Z.N"` 가 GitHub 릴리스 태그 `vX.Y.Z.N`와 항상 일치해야 합니다.
  - `apps/yggdrasill/tools/bump_version.ps1`는 이제 릴리스 bump 시 `version.h`도 함께 갱신하도록 되어 있습니다.
- **PlatformIO(pio) 경로 이슈**
  - Windows에서 `pio`가 PATH에 없을 수 있습니다. 일반적으로 아래 경로에 존재:
    - `%USERPROFILE%\.platformio\penv\Scripts\pio.exe`
  - `apps/yggdrasill/tools/build_msix_with_defines.ps1`는 위 경로를 자동 탐지합니다.
- **빌드 실패인데 “예전 펌웨어.bin” 업로드되는 실수 방지**
  - `.pio/build/.../firmware.bin`은 이전 빌드 산출물이 남아있을 수 있습니다.
  - `build_msix_with_defines.ps1`는 이제 **pio 빌드 실패 시 즉시 중단(fail-fast)** 하도록 되어 있어, 실패한 상태로 stale bin이 배포되지 않게 합니다.
- **M5 자산 포함 확인**
  - 릴리스 자산에 반드시 `m5stack-core2_firmware.bin`이 포함되어야 합니다. (`verify_release.ps1`에서 체크)

### 펌웨어 배포를 "스킵"하는 릴리스(Flutter 앱만 배포)
펌웨어 변경이 없고 이번 릴리스에서 펌웨어 배포를 하지 않는 경우, 아래 옵션으로 **펌웨어 버전.h 갱신/펌웨어 빌드/자산 체크를 모두 스킵**할 수 있습니다.

```powershell
cd apps\yggdrasill
./tools/bump_version.ps1 -SkipFirmwareVersionUpdate

$tag = (Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+(?:\.[0-9]+){2,3})').Matches.Groups[1].Value
gh release create v$tag -R How-Know/Yggdrasill -t v$tag -n "Yggdrasill v$tag" -d

./tools/build_msix_with_defines.ps1 -ReleaseTag v$tag -SkipFirmware

gh release edit v$tag -R How-Know/Yggdrasill --draft=false
cd tools
./verify_release.ps1 -Tag v$tag -SkipFirmware
```

### PowerShell 스크립트 실행 팁(Windows)
- 작업 디렉토리 꼬임으로 `./tools/*.ps1`가 안 잡히는 경우가 있으니, 확실하게 실행하려면:
```powershell
Push-Location C:\Users\harry\Yggdrasill\apps\yggdrasill
& .\tools\build_msix_with_defines.ps1 -ReleaseTag vX.Y.Z.N
Pop-Location
```

### 새 PC 설치(권장 시나리오: 포터블)
1) 릴리스에서 `Yggdrasill_portable_x64.zip` 다운로드
2) 압축 해제 후 `yggdrasill.exe` 실행
3) 이후 업데이트는 앱 내부 "업데이트 확인" 버튼으로 진행

### 참고
- 버전 규칙: `pubspec.yaml`의 `version: x.y.z+N` ↔ `msix_version: x.y.z.N` ↔ AppInstaller `Version="x.y.z.N"`
- AppInstaller `MainPackage.Uri`는 최신 태그(msix 파일)로 자동 갱신됨 (`bump_version.ps1`).




