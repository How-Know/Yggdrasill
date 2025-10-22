$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue | Out-Null

Write-Host "[1/6] Visual Studio Build Tools 설치 확인/설치 시작" -ForegroundColor Cyan
try {
  $vsBuild = Get-Command cl.exe -ErrorAction SilentlyContinue
  if (-not $vsBuild) {
    $override = '--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    winget install -e --id Microsoft.VisualStudio.2022.BuildTools --source winget --accept-source-agreements --accept-package-agreements --override $override
  } else {
    Write-Host "MSVC(cl.exe) 이미 감지됨" -ForegroundColor Green
  }
}
catch { Write-Warning $_ }

Write-Host "[2/6] cl.exe 대기 (최대 15분)" -ForegroundColor Cyan
$retries = 0
while (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
  Start-Sleep -Seconds 10
  $retries = $retries + 1
  if ($retries -ge 90) { throw "MSVC(cl.exe) 감지 시간 초과" }
}
Write-Host "cl.exe 감지 완료" -ForegroundColor Green

Write-Host "[3/6] vcpkg 준비" -ForegroundColor Cyan
if (-not (Test-Path 'C:\tools')) { New-Item -ItemType Directory -Path 'C:\tools' | Out-Null }
if (-not (Test-Path 'C:\tools\vcpkg\.git')) {
  git clone https://github.com/microsoft/vcpkg.git C:\tools\vcpkg
} else {
  Push-Location C:\tools\vcpkg
  git pull --ff-only
  Pop-Location
}
Push-Location C:\tools\vcpkg
& .\bootstrap-vcpkg.bat -disableMetrics
Pop-Location

Write-Host "[4/6] 의존성 설치 (sdl2, parson, mosquitto)" -ForegroundColor Cyan
C:\tools\vcpkg\vcpkg.exe install sdl2:x64-windows parson:x64-windows mosquitto:x64-windows --clean-after-build

Write-Host "[5/6] CMake 구성" -ForegroundColor Cyan
$root = "C:\Users\harry\Yggdrasill\simulator\lvgl"
$build = Join-Path $root 'build-n'
if (-not (Test-Path $build)) { New-Item -ItemType Directory -Path $build | Out-Null }
Push-Location $build
cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=C:/tools/vcpkg/scripts/buildsystems/vcpkg.cmake -DVCPKG_TARGET_TRIPLET=x64-windows

Write-Host "[6/6] Ninja 빌드" -ForegroundColor Cyan
ninja -k 0
Pop-Location

Write-Host "완료: 실행 파일은 build-n 폴더 내에서 생성됩니다." -ForegroundColor Green




