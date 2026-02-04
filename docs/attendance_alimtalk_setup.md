# Attendance AlimTalk (Bizppurio) Setup

## Overview
- `attendance_records` 변화(등원/하원)가 발생하면 큐에 적재됩니다.
- Edge Function `attendance_alimtalk_send`가 큐를 읽어 비즈뿌리오 AlimTalk를 발송합니다.
- 지각 판단은 `student_payment_info.lateness_threshold`를 기준으로 합니다.

## Required Secrets (Supabase)
- `BIZPPURIO_ACCOUNT` (필수)
- `BIZPPURIO_PASSWORD` (필수)
- `BIZPPURIO_DOMAIN` (옵션, 기본값: `api.bizppurio.com`)
- `ALIMTALK_CRON_SECRET` (옵션, 스케줄 호출 시 헤더 보호)
- `ALIMTALK_BATCH_SIZE` (옵션, 기본값 20)
- `ALIMTALK_MAX_ATTEMPTS` (옵션, 기본값 5)

## Academy Settings Table
`academy_alimtalk_settings`에 학원별 템플릿/발신 정보를 등록합니다.

필수 컬럼:
- `sender_key` (카카오 발신 프로필 키)
- `sender_number` (발신번호)
- `arrival_template_code`, `arrival_message_template`
- `departure_template_code`, `departure_message_template`
- `late_template_code`, `late_message_template`

### Template Placeholders
메시지 템플릿에서 다음 키를 치환합니다. `#{key}`, `{key}`, `{{key}}` 형식 모두 지원합니다.
- `academyName`
- `studentName`
- `date` (KST)
- `arrivalTime` (KST)
- `departureTime` (KST)
- `lateMinutes`

예시:
```
[{academyName}] {studentName} 등원 확인: {arrivalTime}
```

## Scheduling
Supabase Scheduled Functions에서 `attendance_alimtalk_send`를 1분 간격으로 실행하세요.
`ALIMTALK_CRON_SECRET`을 사용한다면 요청 헤더에 `x-cron-secret`을 포함해야 합니다.

## Testing Checklist
1. `attendance_records`에 `arrival_time` 또는 `departure_time` 업데이트
2. `attendance_notification_queue`에 `pending` 행 생성 확인
3. `attendance_alimtalk_send` 실행
4. `attendance_notification_logs`에 발송 결과 확인

### Example (Local/Staging)
```sql
-- sample: force arrival enqueue
update public.attendance_records
set arrival_time = now()
where id = '<attendance_id>';
```

```bash
curl -X POST "https://<project>.functions.supabase.co/attendance_alimtalk_send" \
  -H "x-cron-secret: <ALIMTALK_CRON_SECRET>"
```
