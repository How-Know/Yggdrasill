# Lightsail AlimTalk Worker Setup

고정 IP(Lightsail)에서 비즈뿌리오 발송 전용 워커를 실행하는 절차입니다.

## 0) 사전 조건

- Lightsail Ubuntu 인스턴스 running
- 비즈뿌리오 허용 IP 등록 완료
- 아래 값 준비:
  - `SUPABASE_URL`
  - `SUPABASE_SERVICE_ROLE_KEY`
  - `BIZPPURIO_ACCOUNT`
  - `BIZPPURIO_PASSWORD`

## 1) 서버 기본 설치

```bash
sudo apt update
sudo apt install -y git curl
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2
node -v
npm -v
```

## 2) 코드 받기

```bash
cd ~
git clone https://github.com/How-Know/Yggdrasill.git
cd Yggdrasill/gateway
npm install
```

## 3) 환경 변수 파일(.env) 생성

```bash
cat > .env <<'EOF'
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY
BIZPPURIO_ACCOUNT=YOUR_BIZ_ACCOUNT
BIZPPURIO_PASSWORD=YOUR_BIZ_PASSWORD
BIZPPURIO_DOMAIN=api.bizppurio.com
ALIMTALK_BATCH_SIZE=20
ALIMTALK_MAX_ATTEMPTS=5
WORKER_INTERVAL_MS=60000
ALIMTALK_ONLY_TODAY=1
EOF
```

## 4) 1회 테스트 실행

```bash
npm run worker:alimtalk:once
```

정상이라면 콘솔에 `summary` 로그가 나오고 `sent`가 증가할 수 있습니다.

## 5) 상시 실행 (PM2)

```bash
pm2 start src/attendance_alimtalk_worker.js --name ygg-alimtalk-worker
pm2 save
pm2 startup
```

`pm2 startup`가 출력하는 마지막 명령을 한 번 더 실행하면 재부팅 후 자동 시작됩니다.

## 6) 운영 확인

```bash
pm2 status
pm2 logs ygg-alimtalk-worker --lines 200
```

알림 발송 대상은 `student_basic_info.notification_consent = true`인 학생만 포함됩니다.
(`학생 탭 > 알림 동의` 체크 기준)
`student_payment_info`의 알림 플래그(`attendance_notification` 등)는 발송 대상 판정에 사용하지 않습니다.

## 7) 중요: Supabase 스케줄 중복 실행 방지

기존 `attendance_alimtalk_send`를 스케줄로 돌리고 있었다면 중지하세요.
둘 다 돌리면 queue `attempts`가 불필요하게 증가할 수 있습니다.

## 8) 기존 3010 오류 큐 복구 (필요 시)

Supabase SQL Editor에서:

```sql
update public.attendance_notification_queue
set status = 'pending',
    attempts = 0,
    last_error = null,
    sent_at = null
where status = 'error'
  and last_error like 'token_issue_failed:%';
```

## 9) 보강 예약 알림톡 워커 (선택, 별도 프로세스)

보강 예약은 `makeup_notification_queue`를 사용합니다. 출결 워커와 **프로세스를 분리**합니다.

1. 마이그레이션(보강 큐·설정 컬럼·트리거) 적용 후, 테스트 학원에 `makeup_template_code`, `makeup_message_template`, `makeup_alimtalk_enabled = true` 설정.
2. `.env`에 아래 추가:

```bash
MAKEUP_ALIMTALK_ENABLED=1
# 선택: 당일 큐만 (기본과 동일하려면 생략 가능)
MAKEUP_ALIMTALK_ONLY_TODAY_QUEUE=1
```

3. PM2로 **두 번째** 프로세스 기동:

```bash
cd ~/Yggdrasill/gateway
pm2 start src/makeup_alimtalk_worker.js --name ygg-makeup-alimtalk-worker
pm2 save
```

`MAKEUP_ALIMTALK_ENABLED`가 없으면 보강 워커는 즉시 종료하므로, 배포만 해도 출결 경로에 영향이 없습니다.

자세한 롤아웃·검증 SQL·템플릿 변수는 [makeup_alimtalk_setup.md](./makeup_alimtalk_setup.md)를 참고하세요.

