// PM2 ecosystem for the local Mosquitto broker.
// 네이티브 exe라 interpreter:'none'. PM2 CLI의 -c(cron) 플래그 충돌을 피하려 ecosystem 사용.
module.exports = {
  apps: [
    {
      name: 'ygg-mqtt',
      script: 'C:\\Program Files\\mosquitto\\mosquitto.exe',
      args: ['-c', 'C:\\Users\\harry\\Yggdrasill\\gateway\\mosquitto\\ygg.conf'],
      interpreter: 'none',
      autorestart: true,
      max_restarts: 50
    }
  ]
};
