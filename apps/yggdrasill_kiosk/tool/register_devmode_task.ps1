param(
  [string]$Device = 'stanbyme',
  [string]$TaskName = 'Yggdrasill webOS DevMode 연장'
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'extend_devmode.ps1'
$arguments =
  "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Device `"$Device`""

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger `
  -Weekly `
  -WeeksInterval 2 `
  -DaysOfWeek Sunday `
  -At '03:00'
$settings = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Description '스탠바이미 webOS Developer Mode 세션을 만료 전에 연장합니다.' `
  -Force
