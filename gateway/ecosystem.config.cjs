module.exports = {
  apps: [
    {
      name: 'ygg-gateway',
      cwd: __dirname,
      script: 'src/index.js',
      exec_mode: 'fork',
      instances: 1,
      watch: false,
      autorestart: true,
      max_restarts: 20,
      min_uptime: '10s',
      restart_delay: 5000,
      kill_timeout: 10000,
      max_memory_restart: '400M',
      merge_logs: true,
      time: true,
      log_date_format: 'YYYY-MM-DD HH:mm:ss.SSS Z',
      env: {
        NODE_ENV: 'production',
        MQTT_CLEAN_SESSION: 'false',
        MQTT_KEEPALIVE_SEC: '15',
        MQTT_RECONNECT_PERIOD_MS: '3000',
        MQTT_CONNECT_TIMEOUT_MS: '30000',
        GW_HEALTH_INTERVAL_MS: '10000',
        GW_STALE_WARN_MS: '90000',
        GW_STALE_HARD_RESET_MS: '180000',
        GW_STALE_ACTIVITY_WINDOW_MS: '600000',
        GW_RECOVERY_COOLDOWN_MS: '60000'
      }
    }
  ]
};
