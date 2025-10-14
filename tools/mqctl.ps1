param(
  [ValidateSet('validate','plan','apply','rollback')]
  [string]$cmd = 'validate'
)

Write-Host "[mqctl] command = $cmd"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$mig = Join-Path $root 'infra/messaging/migrations/0001_init_mqtt.yml'
$schema = Join-Path $root 'infra/messaging/schemas/homework_command.v1.json'
$spec = Join-Path $root 'infra/messaging/specs/homework_phase.v1.yml'

function Assert-Exists($path) {
  if (!(Test-Path $path)) { throw "Missing: $path" }
}

switch ($cmd) {
  'validate' {
    Assert-Exists $mig
    Assert-Exists $schema
    Assert-Exists $spec
    Write-Host "[mqctl] OK: files present"
  }
  'plan' {
    Write-Host "[mqctl] plan: would register topics/acl/routes from $mig"
  }
  'apply' {
    Write-Host "[mqctl] apply: registering topics/acl/routes (stub)"
  }
  'rollback' {
    Write-Host "[mqctl] rollback: removing topics/routes of version 1 (stub)"
  }
}


