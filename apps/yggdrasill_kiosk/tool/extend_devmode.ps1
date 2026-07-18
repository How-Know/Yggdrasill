param(
  [string]$Device = 'stanbyme'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command ares-launch -ErrorAction SilentlyContinue)) {
  throw 'webOS CLI의 ares-launch를 찾을 수 없습니다.'
}

ares-launch com.palmdts.devmode -p 'extend=true' -d $Device
