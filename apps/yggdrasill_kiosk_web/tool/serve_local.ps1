# 로컬(PC) 브라우저 미리보기용 간단 정적 서버.
# 실행 후 http://localhost:8099 를 Chrome 에서 열어 확인한다.
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
Push-Location $appRoot
try {
  python -m http.server 8099
} finally {
  Pop-Location
}
