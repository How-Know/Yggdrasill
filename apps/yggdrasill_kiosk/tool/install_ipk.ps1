param(
  [Parameter(Mandatory = $true)]
  [string]$IpkPath,
  [string]$Device = 'stanbyme'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $IpkPath)) {
  throw "IPK 파일을 찾을 수 없습니다: $IpkPath"
}
if (-not (Get-Command ares-install -ErrorAction SilentlyContinue)) {
  throw 'webOS CLI의 ares-install을 찾을 수 없습니다.'
}

ares-install --device $Device $IpkPath
ares-launch --device $Device com.howknow.yggdrasill.kiosk
