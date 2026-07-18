#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$APP_ROOT/../yggdrasill/env.local.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Supabase 설정 파일을 찾을 수 없습니다: $ENV_FILE" >&2
  exit 1
fi

cd "$APP_ROOT"
flutter-webos pub get
flutter-webos build webos --release --dart-define-from-file="$ENV_FILE"
