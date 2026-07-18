# Yggdrasill 출석 키오스크

스탠바이미용 가로 4K 출석 키오스크입니다. 학원 공지가 있으면 전체 공지
화면을, 없으면 `assets/poster.png`를 표시합니다.

## Windows 미리보기

기존 학습앱의 로컬 Supabase 설정을 `dart-define`으로 전달합니다.

```powershell
.\tool\run_windows.ps1
```

## webOS 빌드

Ubuntu/WSL2에서 공식 `flutter-webos` SDK, webOS NDK, webOS CLI를 설치한 뒤:

```bash
./tool/build_webos.sh
```

생성된 IPK는 `build/webos/arm/release/ipk/`에 있습니다. TV의 Developer
Mode와 Key Server를 켜고 `stanbyme` 장치를 등록한 뒤 Windows에서 설치할 수
있습니다.

```powershell
.\tool\install_ipk.ps1 -IpkPath <IPK 경로> -Device stanbyme
```

## Developer Mode 자동 연장

TV가 네트워크에 연결된 상태에서 2주마다 연장 명령을 실행하는 Windows
예약 작업을 등록합니다.

```powershell
.\tool\register_devmode_task.ps1 -Device stanbyme
```

세션이 이미 만료되면 자동 연장할 수 없으며 TV에서 Developer Mode를 다시
활성화해야 합니다.
