param(
  [string]$DeviceId = "m5-device-011",
  [string]$PlatformioEnv = "m5-device-011",
  [string]$SerialCommand = "",
  [switch]$Wireless,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$firmwareDir = Resolve-Path (Join-Path $scriptDir "..")
$repoRoot = Resolve-Path (Join-Path $firmwareDir "..\..")
$gatewayDir = Join-Path $repoRoot "gateway"
$pioPath = "pio"
if (-not (Get-Command $pioPath -ErrorAction SilentlyContinue)) {
  $candidate = Join-Path $env:USERPROFILE ".platformio\penv\Scripts\pio.exe"
  if (Test-Path $candidate) {
    $pioPath = $candidate
  }
}

if ($Wireless) {
  $SerialCommand = ""
} elseif ([string]::IsNullOrWhiteSpace($SerialCommand)) {
  $SerialCommand = "`"$pioPath`" device monitor -e $PlatformioEnv"
}

Write-Host "[m5-sync-watch] device=$DeviceId env=$PlatformioEnv"
if ($Wireless) {
  Write-Host "[m5-sync-watch] wireless ack mode (no USB serial required)"
} else {
  Write-Host "[m5-sync-watch] serial=$SerialCommand"
}

Push-Location $gatewayDir
try {
  $nodeArgs = @(
    ".\tools\watch_m5_sync.mjs",
    "--device-id", $DeviceId,
    "--serial-cwd", $firmwareDir
  )
  if ($Wireless) {
    $nodeArgs += "--wireless"
  } else {
    $nodeArgs += @("--serial-command", $SerialCommand)
  }
  $nodeArgs += $ExtraArgs

  & node @nodeArgs
  exit $LASTEXITCODE
}
finally {
  Pop-Location
}
