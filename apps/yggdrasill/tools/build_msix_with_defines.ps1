# requires: gh CLI logged in
param(
  [string]$Repo = 'How-Know/Yggdrasill',
  [string]$ReleaseTag = 'v1.0.3'
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $MyInvocation.MyCommand.Path -Parent) | Out-Null
Set-Location ..

# Read defines from env.local.json (apps/yggdrasill/env.local.json)
$envPath = Join-Path (Get-Location) 'env.local.json'
if(-not (Test-Path $envPath)) { throw "env.local.json not found: $envPath" }
$envJson = Get-Content $envPath -Raw | ConvertFrom-Json
$url = $envJson.SUPABASE_URL
$key = $envJson.SUPABASE_ANON_KEY
if([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($key)) { throw 'Missing SUPABASE_URL or SUPABASE_ANON_KEY' }

# Ensure flutter deps
flutter pub get | Out-Host

# Pre-build Windows with same defines
flutter build windows --release --dart-define=SERVER_ONLY=true --dart-define=SUPABASE_URL=$url --dart-define=SUPABASE_ANON_KEY=$key | Out-Host

# Also put env.local.json next to exe so runtime can find it
$releaseDir = Join-Path (Get-Location) 'build/windows/x64/runner/Release'
Copy-Item $envPath (Join-Path $releaseDir 'env.local.json') -Force

# Pass build args to msix plugin to avoid losing dart-defines
$Env:MSIX_FLUTTER_BUILD_ARGS = "--release --dart-define=SERVER_ONLY=true --dart-define=SUPABASE_URL=$url --dart-define=SUPABASE_ANON_KEY=$key"
flutter pub run msix:create | Out-Host

# Prepare dist directory and copy artifacts
$dist = Join-Path (Get-Location) 'dist'
if(-not (Test-Path $dist)) { New-Item -ItemType Directory $dist | Out-Null }
Copy-Item (Join-Path $releaseDir 'mneme_flutter.msix') (Join-Path $dist 'mneme_flutter.msix') -Force

# Build M5Stack firmware and copy artifact into dist (release asset)
try{
  $repoRoot = Resolve-Path (Join-Path (Get-Location) '..\..')  # apps/yggdrasill -> repo root
  $m5Dir = Join-Path $repoRoot 'firmware\m5stack'
  if(Test-Path $m5Dir){
    Write-Host "[INFO] Building M5Stack firmware (PlatformIO)..." -ForegroundColor Cyan
    $pioExe = $null
    $pioCmd = Get-Command pio -ErrorAction SilentlyContinue
    if($pioCmd){ $pioExe = $pioCmd.Source }
    if(-not $pioExe){
      $guess = Join-Path $env:USERPROFILE '.platformio\penv\Scripts\pio.exe'
      if(Test-Path $guess){ $pioExe = $guess }
    }
    if(-not $pioExe){
      if(Test-Path (Join-Path $dist 'm5stack-core2_firmware.bin')){
        Write-Host "[WARN] PlatformIO(pio)를 찾지 못했습니다. 기존 dist의 m5stack-core2_firmware.bin을 그대로 사용합니다." -ForegroundColor Yellow
      } else {
        Write-Host "[WARN] PlatformIO(pio)를 찾지 못했습니다. M5Stack 펌웨어 빌드를 건너뜁니다." -ForegroundColor Yellow
      }
    } else {
      Push-Location $m5Dir
      & $pioExe run -e m5stack-core2 | Out-Host
      $fw = Join-Path $m5Dir '.pio\build\m5stack-core2\firmware.bin'
      if(Test-Path $fw){
        $out = Join-Path $dist 'm5stack-core2_firmware.bin'
        Copy-Item $fw $out -Force
        Write-Host "[OK] M5Stack firmware copied to $out" -ForegroundColor Green
      } else {
        Write-Host "[WARN] M5Stack firmware.bin 산출물을 찾지 못했습니다: $fw" -ForegroundColor Yellow
      }
      Pop-Location
    }
  }
} catch {
  Write-Host "[WARN] M5Stack 펌웨어 빌드/복사 실패: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Create portable ZIP (x64) from Release folder
try{
  $portableZip = Join-Path $dist 'Yggdrasill_portable_x64.zip'
  if(Test-Path $portableZip){ Remove-Item $portableZip -Force -ErrorAction SilentlyContinue }
  Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $portableZip -Force
  Write-Host "[OK] Portable ZIP created: $portableZip" -ForegroundColor Green
} catch {
  Write-Host "[WARN] Portable ZIP 생성 실패: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Export signing certificate (.cer) next to appinstaller for bootstrap installs
$pubspecPath = Join-Path (Get-Location) 'pubspec.yaml'
$pubRaw = Get-Content $pubspecPath -Raw
$pfxPath = $null
$pfxPass = $null
if($pubRaw -match 'certificate_path:\s*(.+)'){ $pfxPath = ($matches[1].Trim()) }
if($pubRaw -match 'certificate_password:\s*"?([^"\r\n]+)'){ $pfxPass = $matches[1].Trim() }
if([string]::IsNullOrWhiteSpace($pfxPath) -or -not (Test-Path $pfxPath)){
  Write-Host '[WARN] certificate_path를 찾지 못했거나 파일이 없습니다. .cer 내보내기를 생략합니다.' -ForegroundColor Yellow
} else {
  try{
    $cerOut = Join-Path $dist 'howknow_codesign_new.cer'
    $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfxPath, $pfxPass)
    $bytes = $pfxCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    [System.IO.File]::WriteAllBytes($cerOut, $bytes)
    Write-Host "[OK] Exported certificate to $cerOut" -ForegroundColor Green
  } catch {
    Write-Host "[WARN] 인증서 내보내기 실패: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# Copy installer bootstrap script to dist
$installerScript = Join-Path (Join-Path (Get-Location) 'tools') 'Install-Yggdrasill.ps1'
if(Test-Path $installerScript){ Copy-Item $installerScript (Join-Path $dist 'Install-Yggdrasill.ps1') -Force }

# Create helper zip that contains .cer + appinstaller + script
$installerZip = Join-Path $dist 'Yggdrasill_Installer.zip'
$bundleFiles = @()
# Create a memo text with the exact install command
$howto = Join-Path $dist 'Install_HowTo.txt'
Set-Content $howto @(
  '관리자 PowerShell을 열고, 압축을 푼 폴더에서 아래를 그대로 실행하세요.',
  '',
  'Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force',
  '.\\Install-Yggdrasill.ps1 -AlsoImportToRoot'
) -Encoding UTF8

if(Test-Path (Join-Path $dist 'howknow_codesign_new.cer')){ $bundleFiles += (Join-Path $dist 'howknow_codesign_new.cer') }
if(Test-Path (Join-Path $dist 'Yggdrasill.appinstaller')){ $bundleFiles += (Join-Path $dist 'Yggdrasill.appinstaller') }
if(Test-Path (Join-Path $dist 'Install-Yggdrasill.ps1')){ $bundleFiles += (Join-Path $dist 'Install-Yggdrasill.ps1') }
if(Test-Path $howto){ $bundleFiles += $howto }
# (선택) 펌웨어는 설치 ZIP에 꼭 필요하진 않지만, 같이 배포하려면 포함 가능
if(Test-Path (Join-Path $dist 'm5stack-core2_firmware.bin')){ $bundleFiles += (Join-Path $dist 'm5stack-core2_firmware.bin') }
if($bundleFiles.Count -gt 0){
  try{ Compress-Archive -Path $bundleFiles -DestinationPath $installerZip -Force } catch { }
}

# Upload to GitHub release
if(Get-Command gh -ErrorAction SilentlyContinue) {
  $uploadFiles = @()
  $uploadFiles += (Join-Path $dist 'mneme_flutter.msix')
  $uploadFiles += (Join-Path $dist 'Yggdrasill.appinstaller')
  if(Test-Path (Join-Path $dist 'm5stack-core2_firmware.bin')){ $uploadFiles += (Join-Path $dist 'm5stack-core2_firmware.bin') }
  if(Test-Path (Join-Path $dist 'Yggdrasill_portable_x64.zip')){ $uploadFiles += (Join-Path $dist 'Yggdrasill_portable_x64.zip') }
  if(Test-Path (Join-Path $dist 'howknow_codesign_new.cer')){ $uploadFiles += (Join-Path $dist 'howknow_codesign_new.cer') }
  if(Test-Path $installerZip){ $uploadFiles += $installerZip }
  gh release upload $ReleaseTag -R $Repo @uploadFiles --clobber | Out-Host
}

Pop-Location | Out-Null
Write-Host 'DONE'
