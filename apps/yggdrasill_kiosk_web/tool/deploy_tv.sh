#!/usr/bin/env bash
set -euo pipefail

export PATH=/opt/node-v16.20.2-linux-x64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="com.howknow.yggdrasill.kioskweb"
DEVICE="${1:-stanbyme}"
OUT="$APP_DIR/build"

rm -rf "$OUT"
mkdir -p "$OUT"
ares-package "$APP_DIR" -o "$OUT"
IPK="$(ls "$OUT"/*.ipk | head -1)"
echo "IPK=$IPK"

ares-launch --device "$DEVICE" --close "$APP_ID" || true
ares-install --device "$DEVICE" "$IPK"
ares-launch --device "$DEVICE" "$APP_ID"
echo "DONE"
