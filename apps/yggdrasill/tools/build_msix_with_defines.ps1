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

# Copy msix to dist
$dist = Join-Path (Get-Location) 'dist'
if(-not (Test-Path $dist)) { New-Item -ItemType Directory $dist | Out-Null }
Copy-Item (Join-Path $releaseDir 'mneme_flutter.msix') (Join-Path $dist 'mneme_flutter.msix') -Force

# Upload to GitHub release
if(Get-Command gh -ErrorAction SilentlyContinue) {
  gh release upload $ReleaseTag -R $Repo (Join-Path $dist 'mneme_flutter.msix') (Join-Path $dist 'Yggdrasill.appinstaller') --clobber | Out-Host
}

Pop-Location | Out-Null
Write-Host 'DONE'
