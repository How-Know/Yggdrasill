## Yggdrasill Windows 배포 가이드 (MSIX + 포터블 ZIP)

이 문서는 배포 때마다 복붙해서 사용할 수 있는 체크리스트/명령 모음입니다.

### 준비물
- GitHub CLI(gh) 로그인 완료: `gh auth login`
- Flutter 설치/동작
- `apps/yggdrasill/env.local.json`에 `SUPABASE_URL`, `SUPABASE_ANON_KEY` 존재

### 빠른 배포(원라이너)
아래 명령은 버전 증가 → Windows 빌드/MSIX 생성 → ZIP 생성 → GitHub 릴리스 생성/업로드/공개 → 검증까지 일괄 수행합니다.

```powershell
cd apps\yggdrasill; \
./tools/bump_version.ps1; \
./tools/build_msix_with_defines.ps1 -ReleaseTag ((Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Matches.Groups[1].Value | ForEach-Object { 'v'+$_ }); \
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath dist\Yggdrasill_portable_x64.zip -Force; \
$tag=((Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Matches.Groups[1].Value); \
gh release create v$tag -R How-Know/Yggdrasill -t v$tag -n "Yggdrasill v$tag" -d; \
gh release upload v$tag -R How-Know/Yggdrasill dist\mneme_flutter.msix dist\Yggdrasill.appinstaller dist\Yggdrasill_portable_x64.zip dist\Yggdrasill_Installer.zip --clobber; \
gh release edit v$tag -R How-Know/Yggdrasill --draft=false; \
cd tools; ./verify_release.ps1 -Tag v$tag
```

### 안정 단계별 실행(문제 발생 시)
1) 버전/AppInstaller 동기화
```powershell
cd apps\yggdrasill
./tools/bump_version.ps1
```
2) Windows 빌드 + MSIX 생성(환경 주입 포함)
```powershell
./tools/build_msix_with_defines.ps1 -ReleaseTag v((Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Matches.Groups[1].Value)
```
3) 포터블 ZIP 생성
```powershell
if(!(Test-Path dist)){ New-Item -ItemType Directory dist | Out-Null }
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath dist\Yggdrasill_portable_x64.zip -Force
```
4) GitHub 릴리스 생성/업로드/공개
```powershell
$tag=(Get-Content pubspec.yaml -Raw | Select-String 'msix_version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Matches.Groups[1].Value
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

### 새 PC 설치(권장 시나리오)
1) 릴리스에서 `Yggdrasill_Installer.zip`을 내려받아 압축 해제
2) 관리자 PowerShell로 다음 실행
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
./Install-Yggdrasill.ps1 -AlsoImportToRoot
```
위 스크립트는 인증서를 `TrustedPeople`(필요 시 `Root`)에 설치 후 `Yggdrasill.appinstaller`로 설치/업데이트를 진행합니다.

### 참고
- 버전 규칙: `pubspec.yaml`의 `version: x.y.z+N` ↔ `msix_version: x.y.z.N` ↔ AppInstaller `Version="x.y.z.N"`
- AppInstaller `MainPackage.Uri`는 최신 태그(msix 파일)로 자동 갱신됨 (`bump_version.ps1`).




