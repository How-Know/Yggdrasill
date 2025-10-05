param(
  [string]$CertFile = 'HowKnow_CodeSign.cer',
  [string]$AppInstaller = 'Yggdrasill.appinstaller',
  [switch]$AlsoImportToRoot = $false,
  [switch]$Quiet = $false
)

$ErrorActionPreference = 'Stop'

function Info($m){ if(-not $Quiet){ Write-Host "[INFO] $m" -ForegroundColor Cyan } }
function Ok($m){ if(-not $Quiet){ Write-Host "[OK] $m" -ForegroundColor Green } }
function Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

# Move to script directory to simplify relative paths
Push-Location (Split-Path $MyInvocation.MyCommand.Path -Parent) | Out-Null

try{
  if(!(Test-Path $CertFile)){
    Fail "인증서 파일을 찾지 못했습니다: $CertFile"
  }
  if(!(Test-Path $AppInstaller)){
    Fail "App Installer 파일을 찾지 못했습니다: $AppInstaller"
  }

  # Try importing certificate to LocalMachine TrustedPeople first (requires admin)
  try{
    Info "인증서(LocalMachine\\TrustedPeople) 설치 시도"
    Import-Certificate -FilePath $CertFile -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
    Ok 'LocalMachine\\TrustedPeople 설치 완료'
  } catch {
    Warn "LocalMachine 설치 실패(관리자 권한 필요할 수 있음): $($_.Exception.Message)"
    Info "대신 CurrentUser\\TrustedPeople 설치 시도"
    Import-Certificate -FilePath $CertFile -CertStoreLocation Cert:\CurrentUser\TrustedPeople | Out-Null
    Ok 'CurrentUser\\TrustedPeople 설치 완료'
  }

  if($AlsoImportToRoot){
    try{
      Info "인증서(LocalMachine\\Root) 추가 설치 시도"
      Import-Certificate -FilePath $CertFile -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
      Ok 'LocalMachine\\Root 설치 완료'
    } catch {
      Warn "LocalMachine Root 설치 실패: $($_.Exception.Message)"
      Info "대신 CurrentUser\\Root 설치 시도"
      Import-Certificate -FilePath $CertFile -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
      Ok 'CurrentUser\\Root 설치 완료'
    }
  }

  # Optional: ensure Microsoft App Installer is present
  try{
    Info 'Microsoft App Installer 업데이트 확인(선택)'
    if(Get-Command winget -ErrorAction SilentlyContinue){
      winget list --id Microsoft.AppInstaller -e 2>$null | Out-Null
    }
  } catch { }

  Info "App Installer 실행: $AppInstaller"
  Add-AppxPackage -AppInstallerFile $AppInstaller -ForceUpdateFromAnyVersion -ErrorAction Stop | Out-Null
  Ok '설치(또는 업데이트) 완료'
} finally {
  Pop-Location | Out-Null
}


