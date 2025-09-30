# Yggdrasill Monorepo (apps/)

- apps/yggdrasill: Flutter 앱
- apps/survey-web: 설문 웹(React + Vite + TS)

개발 가이드(요약)
- Flutter: `cd apps/yggdrasill` → `flutter pub get` → `flutter run`
- Web(설문): `cd apps/survey-web` → Node 설치 후 `npm i` → `npm run dev`

노트
- 두 프로젝트는 별도 의존성. 디자인 토큰/스키마 공유는 추후 `packages/` 추가 권장.

