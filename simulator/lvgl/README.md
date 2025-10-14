# M5 LVGL+SDL PC Simulator

## Windows (vcpkg) 빌드 방법

1) vcpkg 설치 후 SDL2 설치
```powershell
vcpkg install sdl2
```

2) CMake 구성 및 빌드 (vcpkg 툴체인 사용)
```powershell
cd C:\Users\harry\Yggdrasill\simulator\lvgl
cmake -B build -S . -G "Ninja" -DCMAKE_TOOLCHAIN_FILE=C:/vcpkg/scripts/buildsystems/vcpkg.cmake
cmake --build build
```

3) 실행
```powershell
./build/m5_lvgl_sim
```

초기 화면은 "오늘 등원 목록" 샘플 리스트를 표시합니다. 이후 단계에서 MQTT 연동 및 과제 칩 UI를 추가합니다.

