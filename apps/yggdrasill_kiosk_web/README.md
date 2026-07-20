# Yggdrasill 출석 키오스크 (webOS 웹앱)

LG StanbyME(webOS)용 출석 키오스크. Flutter 네이티브 앱이 webOS에서 겪던
1080p UI 한계·렌더링 깜빡임을 피하기 위해 **웹앱**으로 구현했습니다.
webOS는 웹 기반 플랫폼이라 UI가 패널 해상도로 선명하게 렌더되고 안정적입니다.

빌드 단계 없이 순수 HTML/CSS/JS 로 동작합니다.

## 구성
- `index.html` / `styles.css` / `app.js` — 앱 본체
- `config.js` — Supabase 연결(anon 키는 공개용). `config.example.js` 참고
- `assets/poster.png` — 공지 없을 때 메인 배경 포스터
- `appinfo.json` — webOS 앱 메타(type: web)

## 기능
- iOS 잠금화면 스타일 헤더(날짜·요일·학원명·날씨 + 큰 시계)
- 공지 없으면 포스터, 공지 있으면 공지 화면
- 우측 하단 초록 "출석체크" 버튼 → 오른쪽 슬라이드 시트
- 오늘 등원 예정 학생 목록, 이름 탭 → PIN 등원
- 등원 중인 학생 다시 탭 → PIN 하원
- 학생 이름/초성 검색(다이얼로그)
- 기기 페어링(PIN) → 관리자 승인 후 자동 연결(토큰 localStorage 저장)

## 백엔드
기존 Supabase Edge Function `kiosk_api` 와 RPC 를 그대로 사용합니다.

## 실행
- 로컬 미리보기: `tool/serve_local.ps1` → http://localhost:8099
- TV 배포: `tool/deploy_tv.ps1` (WSL의 ares CLI 사용, device=stanbyme)
