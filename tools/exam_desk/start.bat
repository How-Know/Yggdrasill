@echo off
chcp 65001 >nul
set PYTHONIOENCODING=utf-8
cd /d "%~dp0"
where py >nul 2>&1
if not errorlevel 1 (
  py -3 server.py
  goto done
)
where python >nul 2>&1
if not errorlevel 1 (
  python server.py
  goto done
)
echo Python 3이 필요합니다.
echo https://www.python.org/downloads/ 에서 설치한 뒤 다시 실행하세요.
echo 설치 화면에서 Add python.exe to PATH 를 켜 주세요.
echo.
pause
exit /b 1
:done
echo.
echo 프로그램이 끝났습니다.
pause
