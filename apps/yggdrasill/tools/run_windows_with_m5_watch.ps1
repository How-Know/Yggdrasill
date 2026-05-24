param(
  [string]$DeviceId = "m5-device-006",
  [string]$FlutterDevice = "windows",
  [switch]$PubGet,
  [switch]$SkipPubGet,
  [string[]]$FlutterArgs = @()
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir = Resolve-Path (Join-Path $scriptDir "..")
$repoRoot = Resolve-Path (Join-Path $appDir "..\..")
$watchScript = Join-Path $repoRoot "firmware\m5stack\tools\watch_m5_sync_011.ps1"
$logsDir = Join-Path $repoRoot ".m5-sync-logs"

if (-not (Test-Path $watchScript)) {
  throw "M5 sync watcher script not found: $watchScript"
}

New-Item -ItemType Directory -Force $logsDir | Out-Null

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$watchLog = Join-Path $logsDir "m5-sync-$DeviceId-$stamp.log"
$watchErr = Join-Path $logsDir "m5-sync-$DeviceId-$stamp.err.log"
New-Item -ItemType File -Force $watchLog | Out-Null
New-Item -ItemType File -Force $watchErr | Out-Null
$watchArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", "`"$watchScript`"",
  "-DeviceId", $DeviceId,
  "-Wireless"
)

Write-Host "[run] starting M5 sync watcher for $DeviceId"
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
  throw "M5 sync watcher exited during startup. See: $watchErr"
}

$alertTailJob = Start-Job -ArgumentList $watchLog -ScriptBlock {
  param($path)
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
          Write-Output $line
        }
      }
      $offset = $stream.Position
    } finally {
      $stream.Dispose()
    }
  }
}

function Stop-Watcher {
  if ($null -ne $alertTailJob) {
    Stop-Job $alertTailJob -ErrorAction SilentlyContinue
    Remove-Job $alertTailJob -Force -ErrorAction SilentlyContinue
  }

  if ($null -eq $watchProcess -or $watchProcess.HasExited) {
    return
  }

  Write-Host "[run] stopping M5 sync watcher pid=$($watchProcess.Id)"
  try {
    $children = Get-CimInstance Win32_Process |
      Where-Object { $_.ParentProcessId -eq $watchProcess.Id }
    foreach ($child in $children) {
      Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $watchProcess.Id -Force -ErrorAction SilentlyContinue
  } catch {
    Write-Warning "[run] failed to stop watcher cleanly: $($_.Exception.Message)"
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
  Receive-Job $alertTailJob -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Warning "[m5-sync-alert] $_" }
  Pop-Location
  Stop-Watcher

  if (Test-Path $watchLog) {
    $alerts = Select-String -Path $watchLog -Pattern "^AGENT_M5_SYNC_ALERT" -ErrorAction SilentlyContinue
    if ($alerts) {
      Write-Warning "[run] M5 sync alerts were detected. See: $watchLog"
    }
  }
}
