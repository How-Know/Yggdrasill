#ifndef VERSION_H
#define VERSION_H

// M5Stack 펌웨어 버전
// GitHub Release 태그와 동기화해야 함
#define FIRMWARE_VERSION "1.0.5.1"
#define FIRMWARE_BUILD_DATE __DATE__
#define FIRMWARE_BUILD_TIME __TIME__

// GitHub 저장소 정보 (릴리스 확인용)
#ifndef GITHUB_OWNER
#define GITHUB_OWNER "your-username"  // 빌드 시 -D로 주입 권장
#endif

#ifndef GITHUB_REPO
#define GITHUB_REPO "Yggdrasill"
#endif

#endif // VERSION_H

