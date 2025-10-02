param(
  [Parameter(Mandatory=$true)][string]$Tag,           # e.g. v1.0.3.7
  [string]$Repo = 'How-Know/Yggdrasill'
)

function Fail($msg){ Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }
function Info($msg){ Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Ok($msg){ Write-Host "[OK] $msg" -ForegroundColor Green }

if(-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail 'gh CLI가 필요합니다. https://cli.github.com/' }

# 1) pubspec/msix/appinstaller 버전 동기화 확인
$pub = Get-Content ..\pubspec.yaml -Raw
if($pub -notmatch 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)'){ Fail 'pubspec.yaml version 형식 인식 실패' }
$vMatch = [regex]::Match($pub, 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)')
$ver = $vMatch.Groups[1].Value        # e.g. 1.0.3
$build = $vMatch.Groups[2].Value      # e.g. 7
$expectedMsix = "$ver.$build"        # e.g. 1.0.3.7
if($pub -notmatch 'msix_version:\s*([0-9]+(?:\.[0-9]+){2,3})'){ Fail 'pubspec.yaml msix_version 인식 실패' }
$msix = [regex]::Match($pub, 'msix_version:\s*([0-9]+(?:\.[0-9]+){2,3})').Groups[1].Value
if($msix -ne $expectedMsix){ Fail "msix_version($msix) != expected($expectedMsix) from version/build" } else { Ok "pubspec ok: version=$ver+$build, msix_version=$msix" }

$ai = Get-Content ..\dist\Yggdrasill.appinstaller -Raw
if($ai -notmatch 'Version="([0-9]+(?:\.[0-9]+){2,3})"'){ Fail 'appinstaller Version 인식 실패' }
$aiVer = [regex]::Match($ai, 'Version="([0-9]+(?:\.[0-9]+){2,3})"').Groups[1].Value
if($aiVer -ne $expectedMsix){ Fail "appinstaller Version($aiVer) != expected($expectedMsix)" } else { Ok "appinstaller Version=$aiVer" }

# MSIX Uri는 태그 고정(/download/vX.Y.Z/)를 권장, 루트 AppInstaller Uri는 /latest/ 사용 허용
if($ai -notmatch 'releases\/(download\/v([0-9]+(?:\.[0-9]+){2,3})|latest\/download)\/mneme_flutter.msix'){ Fail 'appinstaller Uri MSIX 경로 인식 실패' }
$m = [regex]::Match($ai, 'releases\/download\/v([0-9]+(?:\.[0-9]+){2,3})\/mneme_flutter.msix')
if($m.Success){
  $aiTag = $m.Groups[1].Value
  if("v$aiTag" -ne $Tag){ Fail "appinstaller Uri tag(v$aiTag) != 입력 Tag($Tag)" } else { Ok "appinstaller Uri tag=v$aiTag" }
} else {
  Info 'appinstaller MSIX Uri가 latest 경로입니다.'
}

# UpdateSettings 강제 업데이트 설정 확인
if($ai -notmatch '<UpdateSettings>'){ Fail 'appinstaller에 <UpdateSettings> 블록이 없습니다.' }
if($ai -notmatch '<OnLaunch\s+HoursBetweenUpdateChecks="0"\s*/>'){ Fail 'OnLaunch HoursBetweenUpdateChecks=0 누락' } else { Ok 'OnLaunch=0 확인' }
if($ai -notmatch '<ShowPrompt>\s*true\s*</ShowPrompt>'){ Fail 'ShowPrompt=true 누락' } else { Ok 'ShowPrompt=true 확인' }
if($ai -notmatch '<UpdateBlocksActivation>\s*true\s*</UpdateBlocksActivation>'){ Fail 'UpdateBlocksActivation=true 누락' } else { Ok 'BlocksActivation=true 확인' }
if($ai -notmatch '<ForceUpdateFromAnyVersion>\s*true\s*</ForceUpdateFromAnyVersion>'){ Fail 'ForceUpdateFromAnyVersion=true 누락' } else { Ok 'ForceUpdateFromAnyVersion=true 확인' }

# 2) 릴리스 자산 확인
Info "릴리스 자산 확인 중: $Repo $Tag"
$json = gh release view $Tag -R $Repo --json assets 2>$null | ConvertFrom-Json
if(-not $json){ Fail '릴리스를 찾지 못했습니다.' }
$names = $json.assets.name
if($names -notcontains 'mneme_flutter.msix'){ Fail 'MSIX 자산이 없습니다.' } else { Ok 'MSIX found' }
if(($names | Where-Object { $_ -match 'Yggdrasill_portable_x64\.zip' }).Count -eq 0){ Fail 'x64 포터블 ZIP이 없습니다.' } else { Ok 'x64 ZIP found' }

# 3) 업데이트 후보 URL과 파일명 일치 여부(간단 점검)
$urls = @(
  'https://github.com/How-Know/Yggdrasill/releases/latest/download/Yggdrasill_portable_x64.zip'
)
foreach($u in $urls){
  try{
    $resp = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -ErrorAction Stop
    if($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400){ Ok "ZIP candidate OK: $u" } else { Fail "ZIP candidate not accessible: $u" }
  } catch { Fail "ZIP candidate check failed: $u" }
}

Ok '모든 검증 통과'

