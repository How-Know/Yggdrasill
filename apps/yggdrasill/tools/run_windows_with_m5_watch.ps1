param(
  [string[]]$DeviceIds = @("m5-device-001", "m5-device-002", "m5-device-003", "m5-device-004", "m5-device-005", "m5-device-006", "m5-device-007", "m5-device-008", "m5-device-009", "m5-device-010", "m5-device-011", "m5-device-012", "m5-device-013", "m5-device-014", "m5-device-015"),
  [string]$DeviceId = "",
  [string]$FlutterDevice = "windows",
  [switch]$PubGet,
  [switch]$SkipPubGet,
  [string[]]$FlutterArgs = @(),
  [switch]$EnableM5Watch
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir = Resolve-Path (Join-Path $scriptDir "..")
$repoRoot = Resolve-Path (Join-Path $appDir "..\..")
$logsDir = Join-Path $repoRoot ".m5-sync-logs"

if (-not [string]::IsNullOrWhiteSpace($DeviceId)) {
  $DeviceIds = @($DeviceId)
}
$DeviceIds = @($DeviceIds | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($DeviceIds.Count -eq 0) {
  throw "At least one M5 device id is required."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$watchers = @()

function Start-AlertTailJob {
  param([string]$Path, [string]$DeviceId)
  Start-Job -ArgumentList $Path, $DeviceId -ScriptBlock {
  param($path, $deviceId)
  $offset = 0
  while ($true) {
    Start-Sleep -Seconds 2
    if (-not (Test-Path $path)) {
      continue
    }
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      if ($stream.Length -lt $offset) {
        $offset = 0
      }
      $stream.Seek($offset, [System.IO.SeekOrigin]::Begin) | Out-Null
      $reader = New-Object System.IO.StreamReader($stream)
      while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($line -match "^AGENT_M5_SYNC_ALERT") {
          Write-Output "[$deviceId] $line"
        }
      }
      $offset = $stream.Position
    } finally {
      $stream.Dispose()
    }
  }
}
}

if ($EnableM5Watch) {
  $watchScript = Join-Path $repoRoot "firmware\m5stack\tools\watch_m5_sync_011.ps1"
  if (-not (Test-Path $watchScript)) {
    throw "M5 sync watcher script not found: $watchScript"
  }

  New-Item -ItemType Directory -Force $logsDir | Out-Null

  foreach ($device in $DeviceIds) {
    $watchLog = Join-Path $logsDir "m5-sync-$device-$stamp.log"
    $watchErr = Join-Path $logsDir "m5-sync-$device-$stamp.err.log"
    New-Item -ItemType File -Force $watchLog | Out-Null
    New-Item -ItemType File -Force $watchErr | Out-Null
    $watchArgs = @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", "`"$watchScript`"",
      "-DeviceId", $device,
      "-Wireless"
    )

    Write-Host "[run] starting M5 sync watcher for $device"
    Write-Host "[run] watcher log: $watchLog"

    $watchProcess = Start-Process `
      -FilePath "powershell" `
      -ArgumentList $watchArgs `
      -WorkingDirectory $repoRoot `
      -RedirectStandardOutput $watchLog `
      -RedirectStandardError $watchErr `
      -PassThru `
      -WindowStyle Hidden

    Start-Sleep -Milliseconds 750
    if ($watchProcess.HasExited) {
      throw "M5 sync watcher exited during startup for $device. See: $watchErr"
    }

    $alertTailJob = Start-AlertTailJob -Path $watchLog -DeviceId $device
    $watchers += [pscustomobject]@{
      DeviceId = $device
      Process = $watchProcess
      AlertTailJob = $alertTailJob
      WatchLog = $watchLog
      WatchErr = $watchErr
    }
  }
} else {
  Write-Host "[run] M5 sync watchers disabled. Use -EnableM5Watch only for diagnostics."
}

function Stop-Watcher {
  foreach ($watcher in $watchers) {
    if ($null -ne $watcher.AlertTailJob) {
      Stop-Job $watcher.AlertTailJob -ErrorAction SilentlyContinue
      Remove-Job $watcher.AlertTailJob -Force -ErrorAction SilentlyContinue
    }

    if ($null -eq $watcher.Process -or $watcher.Process.HasExited) {
      continue
    }

    Write-Host "[run] stopping M5 sync watcher for $($watcher.DeviceId) pid=$($watcher.Process.Id)"
    try {
      $children = Get-CimInstance Win32_Process |
        Where-Object { $_.ParentProcessId -eq $watcher.Process.Id }
      foreach ($child in $children) {
        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
      }
      Stop-Process -Id $watcher.Process.Id -Force -ErrorAction SilentlyContinue
    } catch {
      Write-Warning "[run] failed to stop watcher for $($watcher.DeviceId) cleanly: $($_.Exception.Message)"
    }
  }
}

try {
  Push-Location $appDir

  if ($PubGet -and -not $SkipPubGet) {
    Write-Host "[run] flutter pub get"
    flutter pub get
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "[run] flutter pub get exited with code $LASTEXITCODE; continuing to flutter run"
    }
  }

  $runArgs = @("run", "-d", $FlutterDevice) + $FlutterArgs
  Write-Host "[run] flutter $($runArgs -join ' ')"
  $flutterCommand = "flutter " + ($runArgs -join " ")
  $flutterProcess = Start-Process `
    -FilePath "cmd.exe" `
    -ArgumentList @("/c", $flutterCommand) `
    -WorkingDirectory $appDir `
    -NoNewWindow `
    -Wait `
    -PassThru
  if ($flutterProcess.ExitCode -ne 0) {
    exit $flutterProcess.ExitCode
  }
}
finally {
  foreach ($watcher in $watchers) {
    Receive-Job $watcher.AlertTailJob -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Warning "[m5-sync-alert] $_" }
  }
  Pop-Location
  Stop-Watcher

  foreach ($watcher in $watchers) {
    if (-not (Test-Path $watcher.WatchLog)) {
      continue
    }
    $alerts = Select-String -Path $watcher.WatchLog -Pattern "^AGENT_M5_SYNC_ALERT" -ErrorAction SilentlyContinue
    if ($alerts) {
      Write-Warning "[run] M5 sync alerts were detected for $($watcher.DeviceId). See: $($watcher.WatchLog)"
    }
  }
}
