# Yggdrasill Manager 실행 스크립트

Write-Host "🚀 Yggdrasill Manager 실행 중..." -ForegroundColor Cyan

# env.local.json이 있는지 확인
if (-not (Test-Path "env.local.json")) {
    Write-Host "❌ env.local.json 파일이 없습니다." -ForegroundColor Red
    Write-Host "env.example 파일을 복사하여 env.local.json을 만들어주세요." -ForegroundColor Yellow
    exit 1
}

# Flutter 실행
flutter run -d windows

Write-Host "✅ 앱이 종료되었습니다." -ForegroundColor Green



