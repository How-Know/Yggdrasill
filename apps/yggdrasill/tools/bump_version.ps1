param(
  # 기본 동작: 현재 pubspec.yaml의 build(+N)만 +1
  # -BaseVersion 지정 시: x.y.z 버전을 지정한 값으로 "점프"하고 build는 기본 1로 설정(또는 -Build로 지정)
  [string]$BaseVersion = '',
  [int]$Build = 0,
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
$oldVer = $m.Groups[1].Value
$oldBuild = [int]$m.Groups[2].Value

$ver = $oldVer
$new = $oldBuild + 1

if(-not [string]::IsNullOrWhiteSpace($BaseVersion)){
  if($BaseVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$'){ Fail "-BaseVersion 형식이 올바르지 않습니다: $BaseVersion (예: 1.0.6)" }
  $ver = $BaseVersion.Trim()
  $new = 1
  if($Build -gt 0){ $new = $Build }
}

Info "current=$oldVer+$oldBuild -> new=$ver+$new"

# pubspec replacements
$pubRaw = [regex]::Replace($pubRaw, 'version:\s*[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+', "version: $ver+$new")
$pubRaw = [regex]::Replace($pubRaw, 'msix_version:\s*[0-9]+(?:\.[0-9]+){2,3}', "msix_version: $ver.$new")
Set-Content 'pubspec.yaml' $pubRaw -Encoding UTF8
Ok 'pubspec.yaml updated'

foreach($aiPath in @('dist/Yggdrasill.appinstaller','dist/Yggdrasill_utf8.appinstaller')){
  if(!(Test-Path $aiPath)){ continue }
  $oldMsix = ($oldVer + '.' + $oldBuild)
  $newMsix = ($ver + '.' + $new)
  $ai = Get-Content $aiPath -Raw
  $ai = [regex]::Replace($ai, 'Version="' + [regex]::Escape($oldMsix) + '"', 'Version="' + $newMsix + '"')
  $ai = [regex]::Replace($ai, 'releases/download/v' + [regex]::Escape($oldMsix) + '/mneme_flutter.msix', 'releases/download/v' + $newMsix + '/mneme_flutter.msix')
  Set-Content $aiPath $ai -Encoding UTF8
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

