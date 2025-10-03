param(
  [switch]$NoGit = $false
)
$ErrorActionPreference = 'Stop'

function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Fail($m){ Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

Push-Location (Split-Path $MyInvocation.MyCommand.Path -Parent) | Out-Null
Set-Location ..

if(!(Test-Path 'pubspec.yaml')){ Fail 'pubspec.yaml not found (run from apps/yggdrasill/tools)' }

$pubRaw = Get-Content 'pubspec.yaml' -Raw
$m = [regex]::Match($pubRaw, 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)')
if(-not $m.Success){ Fail 'version parse failed in pubspec.yaml' }
$ver = $m.Groups[1].Value
$build = [int]$m.Groups[2].Value
$new = $build + 1
Info "current=$ver+$build -> new=$ver+$new"

# pubspec replacements
$pubRaw = [regex]::Replace($pubRaw, 'version:\s*' + [regex]::Escape($ver) + '\+' + [regex]::Escape($build.ToString()), "version: $ver+$new")
$pubRaw = [regex]::Replace($pubRaw, 'msix_version:\s*' + [regex]::Escape($ver) + '\.' + [regex]::Escape($build.ToString()), "msix_version: $ver.$new")
Set-Content 'pubspec.yaml' $pubRaw
Ok 'pubspec.yaml updated'

foreach($aiPath in @('dist/Yggdrasill.appinstaller','dist/Yggdrasill_utf8.appinstaller')){
  if(!(Test-Path $aiPath)){ continue }
  $ai = Get-Content $aiPath -Raw
  $ai = [regex]::Replace($ai, 'Version="' + [regex]::Escape($ver + '.' + $build) + '"', 'Version="' + ($ver + '.' + $new) + '"')
  $ai = [regex]::Replace($ai, 'releases/download/v' + [regex]::Escape($ver + '.' + $build) + '/mneme_flutter.msix', 'releases/download/v' + ($ver + '.' + $new) + '/mneme_flutter.msix')
  Set-Content $aiPath $ai
  Ok "$aiPath updated"
}

if(-not $NoGit){
  git add -A | Out-Null
  git commit -m ("chore(release): bump to $ver.$new") | Out-Null
  git push | Out-Null
  Ok 'git push done'
}

Write-Host ("NEW_TAG=v{0}.{1}" -f $ver, $new)

Pop-Location | Out-Null

