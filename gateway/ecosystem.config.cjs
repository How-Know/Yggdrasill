module.exports = {
  apps: [
    {
      name: 'ygg-gateway',
      cwd: __dirname,
      script: 'src/index.js',
      exec_mode: 'fork',
      instances: 1,
      // 개발 편의: 게이트웨이 소스 수정 시 자동 재시작 (M5 게이트웨이 본체만 감시)
      watch: ['src/index.js', 'src/m5_sync_fingerprint.js'],
      ignore_watch: ['node_modules', 'logs', 'output', 'tmp', '.git'],
      watch_options: { usePolling: true, interval: 1000 },
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
    },
    {
      name: 'ygg-makeup-alimtalk-worker',
      cwd: __dirname,
      script: 'src/makeup_alimtalk_worker.js',
      exec_mode: 'fork',
      instances: 1,
      watch: false,
      autorestart: true,
      max_restarts: 20,
      min_uptime: '10s',
      restart_delay: 5000,
      kill_timeout: 10000,
      max_memory_restart: '200M',
      merge_logs: true,
      time: true,
      log_date_format: 'YYYY-MM-DD HH:mm:ss.SSS Z',
      // 서버 .env에 MAKEUP_ALIMTALK_ENABLED=1 없으면 워커는 시작 직후 종료(무해).
      env: {
        NODE_ENV: 'production',
        MAKEUP_ALIMTALK_ENABLED: process.env.MAKEUP_ALIMTALK_ENABLED || '0'
      }
    },
    // === 문제은행(서버 PDF) API + 워커들 ===
    // 렌더링 산출물 파일 쓰기로 인한 watch 재시작 루프를 피하기 위해 watch=false.
    // (게이트웨이 본체만 편집 시 자동 재시작. 워커 코드 수정 후엔 `pm2 restart`).
    {
      name: 'ygg-pb-api',
      cwd: __dirname,
      script: 'src/problem_bank_api.js',
      exec_mode: 'fork',
      instances: 1,
      watch: false,
      autorestart: true,
      max_restarts: 20,
      min_uptime: '10s',
      restart_delay: 5000,
      kill_timeout: 10000,
      max_memory_restart: '700M',
      merge_logs: true,
      time: true,
      log_date_format: 'YYYY-MM-DD HH:mm:ss.SSS Z',
      env: { NODE_ENV: 'production' }
    },
    {
      name: 'ygg-pb-extract',
      cwd: __dirname,
      script: 'src/problem_bank_extract_worker.js',
      exec_mode: 'fork',
      instances: 1,
      watch: false,
      autorestart: true,
      max_restarts: 20,
      min_uptime: '10s',
      restart_delay: 5000,
      kill_timeout: 10000,
      max_memory_restart: '700M',
      merge_logs: true,
      time: true,
      log_date_format: 'YYYY-MM-DD HH:mm:ss.SSS Z',
      env: { NODE_ENV: 'production' }
    },
    {
      name: 'ygg-pb-figure',
      cwd: __dirname,
      script: 'src/problem_bank_figure_worker.js',
      exec_mode: 'fork',
      instances: 1,
      watch: false,
      autorestart: true,
      max_restarts: 20,
      min_uptime: '10s',
      restart_delay: 5000,
      kill_timeout: 10000,
      max_memory_restart: '700M',
      merge_logs: true,
      time: true,
      log_date_format: 'YYYY-MM-DD HH:mm:ss.SSS Z',
      env: { NODE_ENV: 'production' }
    },
    {
      name: 'ygg-pb-export',
      cwd: __dirname,
      script: 'src/problem_bank_export_worker.js',
      exec_mode: 'fork',
      instances: 1,
      watch: false,
      autorestart: true,
      max_restarts: 20,
      min_uptime: '10s',
      restart_delay: 5000,
      kill_timeout: 10000,
      max_memory_restart: '900M',
      merge_logs: true,
      time: true,
      log_date_format: 'YYYY-MM-DD HH:mm:ss.SSS Z',
      env: { NODE_ENV: 'production' }
    }
  ]
};
