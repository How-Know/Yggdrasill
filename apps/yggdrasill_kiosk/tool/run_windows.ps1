$ErrorActionPreference = 'Stop'

$appRoot = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $appRoot '..\yggdrasill\env.local.json'

if (-not (Test-Path -LiteralPath $envFile)) {
  throw "Supabase 설정 파일을 찾을 수 없습니다: $envFile"
}

Push-Location $appRoot
try {
  flutter run -d windows --dart-define-from-file="$envFile"
} finally {
  Pop-Location
}
