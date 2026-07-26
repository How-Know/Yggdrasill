#!/bin/bash
# MyScript iink SDK 4.5 xcframework 다운로드 스크립트.
#
# libiink.xcframework(500MB+)는 git 에 커밋하지 않는다.
# 새 머신에서 iOS 빌드 전에 이 스크립트를 한 번 실행하면 된다:
#   cd apps/yggdrasill_student/ios/MyScriptMath && ./fetch_iink_sdk.sh
set -euo pipefail

VERSION="4.5.0"
SHA256="d659b88e2cae3a512e5bc8d2a1ea9e2dda365302b81b1887a2f90d6c3f69b96f"
URL="https://github.com/MyScript/interactive-ink-packages-ios/releases/download/${VERSION}/MyScriptSDK-libiink.xcframework.zip"

cd "$(dirname "$0")"

if [ -d "Frameworks/libiink.xcframework" ]; then
  echo "libiink.xcframework already present — nothing to do."
  exit 0
fi

echo "Downloading iink SDK ${VERSION}..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -sL -o "$tmp/iink.zip" "$URL"

echo "Verifying checksum..."
actual="$(shasum -a 256 "$tmp/iink.zip" | awk '{print $1}')"
if [ "$actual" != "$SHA256" ]; then
  echo "Checksum mismatch: $actual (expected $SHA256)" >&2
  exit 1
fi

mkdir -p Frameworks
unzip -q "$tmp/iink.zip" -d "$tmp/out"
mv "$tmp/out/libiink.xcframework" Frameworks/

# MyScript 배포본의 modulemap 은 'module libiink' 로 선언돼 있어
# 프레임워크 모듈로 인식되지 않는다 (umbrella 헤더가 스킵되어 import 실패).
# 'framework module' 한정자를 붙여 준다.
for mm in Frameworks/libiink.xcframework/*/libiink.framework/Modules/module.modulemap; do
  sed -i '' 's/^module libiink {/framework module libiink {/' "$mm"
done
# modulemap 수정으로 원본 서명이 깨지므로 서명을 제거한다 (앱 빌드시 재서명됨).
rm -rf Frameworks/libiink.xcframework/_CodeSignature

echo "Done: Frameworks/libiink.xcframework"
