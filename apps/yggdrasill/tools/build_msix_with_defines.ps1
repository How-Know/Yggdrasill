# requires: gh CLI logged in
param(
  [string]$Repo = 'How-Know/Yggdrasill',
  [string]$ReleaseTag = 'v1.0.3',
  # 펌웨어를 이번 릴리스에서 배포하지 않을 때(빌드/자산 업로드 스킵)
  [switch]$SkipFirmware = $false,
  # MSIX/AppInstaller/인증서/Installer.zip 없이 포터블 ZIP만 배포할 때
  [switch]$PortableOnly = $false
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
if($LASTEXITCODE -ne 0){ throw "flutter build windows failed (exit=$LASTEXITCODE)" }

# Also put env.local.json next to exe so runtime can find it
$releaseDir = Join-Path (Get-Location) 'build/windows/x64/runner/Release'
Copy-Item $envPath (Join-Path $releaseDir 'env.local.json') -Force

# Portable 배포 안정성 체크: VC++ 런타임 DLL이 번들에 존재해야 ARM/x64 신규 PC에서 실행 가능
$requiredRuntimeDlls = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$missingRuntimeDlls = @()
foreach($dll in $requiredRuntimeDlls){
  if(-not (Test-Path (Join-Path $releaseDir $dll))){
    $missingRuntimeDlls += $dll
  }
}
if($missingRuntimeDlls.Count -gt 0){
  throw "Missing VC++ runtime DLLs in Release output: $($missingRuntimeDlls -join ', '). windows/CMakeLists.txt runtime bundling 확인 필요"
}

# Prepare dist directory and copy artifacts
$dist = Join-Path (Get-Location) 'dist'
if(-not (Test-Path $dist)) { New-Item -ItemType Directory $dist | Out-Null }

if(-not $PortableOnly){
  # Pass build args to msix plugin to avoid losing dart-defines
  $Env:MSIX_FLUTTER_BUILD_ARGS = "--release --dart-define=SERVER_ONLY=true --dart-define=SUPABASE_URL=$url --dart-define=SUPABASE_ANON_KEY=$key"
  flutter pub run msix:create | Out-Host
  Copy-Item (Join-Path $releaseDir 'mneme_flutter.msix') (Join-Path $dist 'mneme_flutter.msix') -Force
} else {
  Write-Host "[INFO] PortableOnly: skip msix:create and MSIX artifact copy" -ForegroundColor Cyan
}

# Build M5Stack firmware and copy artifact into dist (release asset)
if($SkipFirmware){
  Write-Host "[INFO] Skip M5Stack firmware build/upload (-SkipFirmware)" -ForegroundColor Cyan
} else {
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
        throw "PlatformIO(pio)를 찾지 못했습니다. (PATH 또는 $env:USERPROFILE\\.platformio\\penv\\Scripts\\pio.exe 확인)"
      } else {
        Push-Location $m5Dir
        $fw = Join-Path $m5Dir '.pio\build\m5stack-core2\firmware.bin'
        # 실패 시 이전 산출물 복사되는 문제 방지: 기존 파일 제거
        if(Test-Path $fw){ Remove-Item $fw -Force -ErrorAction SilentlyContinue }
        & $pioExe run -e m5stack-core2 | Out-Host
        if($LASTEXITCODE -ne 0){ throw "pio build failed (exit=$LASTEXITCODE)" }
        if(Test-Path $fw){
          $out = Join-Path $dist 'm5stack-core2_firmware.bin'
          Copy-Item $fw $out -Force
          Write-Host "[OK] M5Stack firmware copied to $out" -ForegroundColor Green
        } else {
          throw "M5Stack firmware.bin 산출물을 찾지 못했습니다: $fw"
        }
        Pop-Location
      }
    }
  } catch {
    throw
  }
}

# Create portable ZIP (x64) from Release folder
try{
  $portableZip = Join-Path $dist 'Yggdrasill_portable_x64.zip'
  if(Test-Path $portableZip){ Remove-Item $portableZip -Force -ErrorAction SilentlyContinue }
  Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $portableZip -Force
  Write-Host "[OK] Portable ZIP created: $portableZip" -ForegroundColor Green
} catch {
  if($PortableOnly){
    throw "Portable ZIP 생성 실패(PortableOnly): $($_.Exception.Message)"
  }
  Write-Host "[WARN] Portable ZIP 생성 실패: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Export signing certificate (.cer) next to appinstaller for bootstrap installs
$pubspecPath = Join-Path (Get-Location) 'pubspec.yaml'
$pubRaw = Get-Content $pubspecPath -Raw
$pfxPath = $null
$pfxPass = $null
if($pubRaw -match 'certificate_path:\s*(.+)'){ $pfxPath = ($matches[1].Trim()) }
if($pubRaw -match 'certificate_password:\s*"?([^"\r\n]+)'){ $pfxPass = $matches[1].Trim() }

if($PortableOnly){
  Write-Host "[INFO] PortableOnly: skip certificate export / installer bundle" -ForegroundColor Cyan
} else {
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
  if(-not $SkipFirmware){
    if(Test-Path (Join-Path $dist 'm5stack-core2_firmware.bin')){ $bundleFiles += (Join-Path $dist 'm5stack-core2_firmware.bin') }
  }
  if($bundleFiles.Count -gt 0){
    try{ Compress-Archive -Path $bundleFiles -DestinationPath $installerZip -Force } catch { }
  }
}

# Upload to GitHub release
if(Get-Command gh -ErrorAction SilentlyContinue) {
  $uploadFiles = @()
  if(-not $PortableOnly){
    $uploadFiles += (Join-Path $dist 'mneme_flutter.msix')
    $uploadFiles += (Join-Path $dist 'Yggdrasill.appinstaller')
  }
  if(-not $SkipFirmware){
    if(Test-Path (Join-Path $dist 'm5stack-core2_firmware.bin')){ $uploadFiles += (Join-Path $dist 'm5stack-core2_firmware.bin') }
  }
  if(Test-Path (Join-Path $dist 'Yggdrasill_portable_x64.zip')){ $uploadFiles += (Join-Path $dist 'Yggdrasill_portable_x64.zip') }
  if(-not $PortableOnly){
    if(Test-Path (Join-Path $dist 'howknow_codesign_new.cer')){ $uploadFiles += (Join-Path $dist 'howknow_codesign_new.cer') }
    if(Test-Path $installerZip){ $uploadFiles += $installerZip }
  }
  gh release upload $ReleaseTag -R $Repo @uploadFiles --clobber | Out-Host
  if($LASTEXITCODE -ne 0){ throw "gh release upload failed (exit=$LASTEXITCODE)" }
}

Pop-Location | Out-Null
Write-Host 'DONE'
