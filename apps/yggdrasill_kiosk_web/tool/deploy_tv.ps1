# webOS 웹앱을 패키징해 StanbyME(stanbyme)에 설치·실행한다.
# ares CLI 는 WSL(Ubuntu)에 설치되어 있으므로 WSL 을 통해 실행한다.
$ErrorActionPreference = 'Stop'

$appDir = '/mnt/c/Users/harry/Yggdrasill/apps/yggdrasill_kiosk_web'
$appId = 'com.howknow.yggdrasill.kioskweb'
$device = 'stanbyme'

$bash = @"
export PATH=/opt/node-v16.20.2-linux-x64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -e
rm -rf /tmp/kioskweb_ipk && mkdir -p /tmp/kioskweb_ipk
ares-package '$appDir' -o /tmp/kioskweb_ipk
IPK=`$(ls /tmp/kioskweb_ipk/*.ipk | head -1)
echo "IPK: `$IPK"
ares-launch --device $device --close $appId || true
ares-install --device $device "`$IPK"
ares-launch --device $device $appId
"@

wsl -d Ubuntu -u root -- bash -lc $bash
