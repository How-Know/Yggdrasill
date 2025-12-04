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
if($bundleFiles.Count -gt 0){
  try{ Compress-Archive -Path $bundleFiles -DestinationPath $installerZip -Force } catch { }
}

# Upload to GitHub release
if(Get-Command gh -ErrorAction SilentlyContinue) {
  $uploadFiles = @()
  $uploadFiles += (Join-Path $dist 'mneme_flutter.msix')
  $uploadFiles += (Join-Path $dist 'Yggdrasill.appinstaller')
  if(Test-Path $installerZip){ $uploadFiles += $installerZip }
  gh release upload $ReleaseTag -R $Repo @uploadFiles --clobber | Out-Host
}

Pop-Location | Out-Null
Write-Host 'DONE'
