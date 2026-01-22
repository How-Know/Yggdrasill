## Yggdrasill Windows 배포 가이드 (MSIX + 포터블 ZIP)

이 문서는 배포 때마다 복붙해서 사용할 수 있는 체크리스트/명령 모음입니다.

### 준비물
- GitHub CLI(gh) 로그인 완료: `gh auth login`
- Flutter 설치/동작
- `apps/yggdrasill/env.local.json`에 `SUPABASE_URL`, `SUPABASE_ANON_KEY` 존재

### 빠른 배포(복붙 스크립트)
아래 명령은 버전 증가 → Windows 빌드/MSIX 생성 → ZIP 생성 → GitHub 릴리스 생성/업로드/공개 → 검증까지 일괄 수행합니다.

```powershell
cd apps\yggdrasill
./tools/bump_version.ps1

$tag = (Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+(?:\.[0-9]+){2,3})').Matches.Groups[1].Value
gh release create v$tag -R How-Know/Yggdrasill -t v$tag -n "Yggdrasill v$tag" -d

# MSIX + appinstaller + Installer.zip(인증서/스크립트/appinstaller 포함) 생성 및 업로드
./tools/build_msix_with_defines.ps1 -ReleaseTag v$tag

# 포터블 ZIP 생성 및 업로드
if(!(Test-Path dist)){ New-Item -ItemType Directory dist | Out-Null }
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath dist\Yggdrasill_portable_x64.zip -Force
gh release upload v$tag -R How-Know/Yggdrasill dist\Yggdrasill_portable_x64.zip --clobber

# 릴리스 공개 + 검증
gh release edit v$tag -R How-Know/Yggdrasill --draft=false
cd tools
./verify_release.ps1 -Tag v$tag
```

### 안정 단계별 실행(문제 발생 시)
1) 버전/AppInstaller 동기화
```powershell
cd apps\yggdrasill
./tools/bump_version.ps1
```
2) Windows 빌드 + MSIX 생성(환경 주입 포함)
```powershell
$tag = (Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+(?:\.[0-9]+){2,3})').Matches.Groups[1].Value
./tools/build_msix_with_defines.ps1 -ReleaseTag v$tag
```
3) 포터블 ZIP 생성
```powershell
if(!(Test-Path dist)){ New-Item -ItemType Directory dist | Out-Null }
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath dist\Yggdrasill_portable_x64.zip -Force
```
4) GitHub 릴리스 생성/업로드/공개
```powershell
$tag = (Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+(?:\.[0-9]+){2,3})').Matches.Groups[1].Value
gh release create v$tag -R How-Know/Yggdrasill -t v$tag -n "Yggdrasill v$tag" -d
gh release upload v$tag -R How-Know/Yggdrasill dist\mneme_flutter.msix dist\Yggdrasill.appinstaller dist\Yggdrasill_portable_x64.zip dist\Yggdrasill_Installer.zip --clobber
gh release edit v$tag -R How-Know/Yggdrasill --draft=false
```
5) 검증
```powershell
cd tools
./verify_release.ps1 -Tag v$tag
```

### App Installer 정책(비차단 자동 업데이트)
- `dist/Yggdrasill*.appinstaller`는 다음 속성을 유지:
  - `OnLaunch HoursBetweenUpdateChecks="0"`
  - `ShowPrompt="false"` (무팝업)
  - `UpdateBlocksActivation="false"` (앱 실행 차단 안 함)
- 앱 내부에서는 시작 시 상단 로딩 카드(앱명/버전/진행) 표시, 준비 완료 시 재시작 버튼 노출.

### 문제 해결(Troubleshooting)
- pubspec 인코딩 오류: 아래로 강제 저장
```powershell
Set-Content apps\yggdrasill\pubspec.yaml (Get-Content apps\yggdrasill\pubspec.yaml -Raw) -Encoding UTF8
```
- 릴리스 생성 오류(원라이너 실패): 위의 "안정 단계별 실행"으로 분리 실행
- "release not found": 릴리스 create가 실패한 상태 → 다시 4) 실행
- gh CLI 미설치: https://cli.github.com 설치 후 `gh auth login`
- ARM64 장비: App Installer 사용이 제한될 수 있음 → ZIP(포터블) 설치 경로로 유도

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

### PowerShell 스크립트 실행 팁(Windows)
- 작업 디렉토리 꼬임으로 `./tools/*.ps1`가 안 잡히는 경우가 있으니, 확실하게 실행하려면:
```powershell
Push-Location C:\Users\harry\Yggdrasill\apps\yggdrasill
& .\tools\build_msix_with_defines.ps1 -ReleaseTag vX.Y.Z.N
Pop-Location
```

### 새 PC 설치(권장 시나리오)
1) 릴리스에서 `Yggdrasill_Installer.zip`을 내려받아 압축 해제
2) 관리자 PowerShell로 다음 실행
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
./Install-Yggdrasill.ps1 -AlsoImportToRoot
```
위 스크립트는 인증서를 `TrustedPeople`(필요 시 `Root`)에 설치 후 `Yggdrasill.appinstaller`로 설치/업데이트를 진행합니다.

> 구버전 릴리스에서 `Yggdrasill.appinstaller`가 ZIP에 포함되지 않은 경우, 아래처럼 Raw URL을 직접 지정하면 진행 가능합니다.
```powershell
./Install-Yggdrasill.ps1 -AlsoImportToRoot -AppInstaller "https://raw.githubusercontent.com/How-Know/Yggdrasill/main/apps/yggdrasill/dist/Yggdrasill.appinstaller"
```

### 참고
- 버전 규칙: `pubspec.yaml`의 `version: x.y.z+N` ↔ `msix_version: x.y.z.N` ↔ AppInstaller `Version="x.y.z.N"`
- AppInstaller `MainPackage.Uri`는 최신 태그(msix 파일)로 자동 갱신됨 (`bump_version.ps1`).




