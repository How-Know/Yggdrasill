param(
  [string]$CertFile = 'howknow_codesign_new.cer',
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

  # Ensure ms-appinstaller protocol is enabled (Windows 10/11 security patch default = disabled)
  $protocolPaths = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\AppInstaller',
    'HKCU:\SOFTWARE\Policies\Microsoft\AppInstaller'
  )
  $protocolEnabled = $false
  foreach($regPath in $protocolPaths){
    try{
      Info "ms-appinstaller 프로토콜 활성화 시도: $regPath"
      if(!(Test-Path $regPath)){
        New-Item -Path $regPath -Force | Out-Null
      }
      New-ItemProperty -Path $regPath -Name 'EnableMSAppInstallerProtocol' -PropertyType DWord -Value 1 -Force | Out-Null
      Ok "EnableMSAppInstallerProtocol=1 적용 ($regPath)"
      $protocolEnabled = $true
      break
    } catch {
      Warn "프로토콜 활성화 실패($regPath): $($_.Exception.Message)"
    }
  }
  if(-not $protocolEnabled){
    Warn "ms-appinstaller 프로토콜 활성화에 실패했습니다. 관리자 PowerShell에서 `reg add HKLM\\SOFTWARE\\Policies\\Microsoft\\AppInstaller /v EnableMSAppInstallerProtocol /t REG_DWORD /d 1 /f` 를 수동 실행해 주세요."
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
  try{
    # 일부 OS/PowerShell 버전에서 -ForceUpdateFromAnyVersion가 파라미터셋 충돌을 유발하므로 사용하지 않음
    Add-AppxPackage -AppInstallerFile $AppInstaller -ErrorAction Stop | Out-Null
    Ok '설치(또는 업데이트) 완료'
  } catch {
    Warn ("Add-AppxPackage -AppInstallerFile 실패: {0}" -f $_.Exception.Message)
    # 폴백: App Installer 프로토콜 호출 (GUI 열림)
    $abs = (Resolve-Path $AppInstaller).Path
    Info "ms-appinstaller 프로토콜로 폴백 실행"
    Start-Process ("ms-appinstaller:?source={0}" -f $abs) | Out-Null
    Ok 'App Installer를 통해 설치 창을 열었습니다.'
  }
} finally {
  Pop-Location | Out-Null
}


