# Makeup reservation AlimTalk (보강 예약 알림톡)

출결 알림톡과 **별도 큐·별도 워커**로 동작합니다. 기본값이 꺼져 있어 마이그레이션만 적용해도 발송은 발생하지 않습니다.

## Product decisions (고정)

| 항목 | 결정 |
|------|------|
| **보강 유형** | `override_type`이 **`replace`와 `add` 모두** 큐에 적재합니다. (`add`만 제외하려면 마이그레이션 트리거 조건을 수정하세요.) |
| **당일 과거 시각** | 큐 적재는 **KST 날짜**가 오늘 이상이면 됩니다. **같은 날이라도 이미 지난 시각**도 포함됩니다(당일 과거만 제외하려면 트리거에 시각 비교 추가 필요). |
| **재발송** | `session_overrides` **INSERT** 시에만 큐 적재합니다. 수정 UPDATE로는 재발송하지 않습니다. |
| **중복** | `(session_override_id, event_type)` 유니크로 동일 보강·이벤트 중복 적재를 막습니다. |

## 데이터 흐름

1. 앱이 `session_overrides`에 planned 보강을 INSERT.
2. DB 트리거가 조건 충족 시 `makeup_notification_queue`에 `pending` 행 삽입.
3. Lightsail의 **보강 전용** Node 워커가 큐를 소비해 비즈뿌리오로 발송하고 `makeup_notification_logs`에 기록.

## 롤아웃 순서 (운영 무영향)

1. **Supabase 마이그레이션 적용** — `20260410120000_makeup_alimtalk_queue.sql` (또는 해당 변경이 포함된 배포). `makeup_alimtalk_enabled` 기본 `false` → 발송 없음.
2. **Gateway 배포** — `makeup_alimtalk_worker.js` 포함. PM2에 보강 워커를 넣더라도 **`MAKEUP_ALIMTALK_ENABLED`를 비우면** 프로세스는 즉시 종료하므로 부하 없음.
3. **학원 설정** — 레포의 [`supabase/scripts/apply_makeup_alimtalk_template.sql`](../supabase/scripts/apply_makeup_alimtalk_template.sql)를 Supabase SQL Editor에서 실행하거나 `supabase db query --linked -f supabase/scripts/apply_makeup_alimtalk_template.sql`로 적용(템플릿 코드는 스크립트에 반영). 학원별로만 켜려면 해당 파일의 `WHERE`에 `academy_id` 조건을 추가하세요.
4. **보강 워커 기동** — `MAKEUP_ALIMTALK_ENABLED=1`로 PM2 등록 후 로그·로그 테이블로 1건 검증.
5. 필요 시 타 학원에 `makeup_alimtalk_enabled` 확대.

## 학원 설정 (`academy_alimtalk_settings`)

출결과 동일하게 `enabled`, `sender_key`, `sender_number` 등이 이미 있어야 합니다. 보강 전용:

- `makeup_template_code` — 비즈 심사 템플릿 코드
- `makeup_message_template` — 치환용 본문(워커가 변수 채움)
- `makeup_alimtalk_enabled` — **`true`**일 때만 보강 알림톡 발송

### 예시 (SQL)

```sql
update public.academy_alimtalk_settings
set
  makeup_template_code = 'YOUR_TEMPLATE_CODE',
  makeup_message_template = '[#{학원명}] #{학생명} 보강 예약: 원래 #{원래수업일시} → #{보강수업일시} (#{변경사유})',
  makeup_alimtalk_enabled = true
where academy_id = 'YOUR_ACADEMY_UUID';
```

## 템플릿 변수

워커가 다음 키를 치환합니다. `#{key}`, `{key}`, `{{key}}` 형식 모두 지원.

| 한글 | 영문 | 설명 |
|------|------|------|
| 학원명 | academyName | 학원 이름 |
| 학생명 | studentName | 학생 이름 |
| 원래수업일시 | originalClassDateTime | KST `M/D(요) HH:mm` |
| 보강수업일시 | replacementClassDateTime | KST `M/D(요) HH:mm` |
| 변경사유 | changeReason | `change_reason` 또는 `reason` |

## 환경 변수 (보강 워커)

Lightsail `.env`에 출결 워커와 동일하게 `SUPABASE_*`, `BIZPPURIO_*` 필요.

| 변수 | 설명 |
|------|------|
| **`MAKEUP_ALIMTALK_ENABLED=1`** | 없으면 워커는 시작 직후 종료(안전 스위치). |
| `MAKEUP_ALIMTALK_BATCH_SIZE` | 기본: `ALIMTALK_BATCH_SIZE` 또는 20 |
| `MAKEUP_ALIMTALK_MAX_ATTEMPTS` | 기본: `ALIMTALK_MAX_ATTEMPTS` 또는 5 |
| `MAKEUP_WORKER_INTERVAL_MS` | 기본: `WORKER_INTERVAL_MS` 또는 60000 |
| `MAKEUP_ALIMTALK_ONLY_TODAY_QUEUE` | 기본 `1`: KST 당일 생성 큐만 처리. `0`이면 전체 `pending`(백필·재시작 시 주의). |

## PM2 예시 (출결과 병행)

```bash
cd ~/Yggdrasill/gateway
# .env에 MAKEUP_ALIMTALK_ENABLED=1 추가 후
pm2 start src/makeup_alimtalk_worker.js --name ygg-makeup-alimtalk-worker
pm2 save
```

출결 워커 `ygg-alimtalk-worker`는 그대로 두면 됩니다.

## 검증 SQL

```sql
-- 최근 큐 (테스트 학원)
select id, session_override_id, status, attempts, last_error, created_at
from public.makeup_notification_queue
where academy_id = 'YOUR_ACADEMY_UUID'
order by created_at desc
limit 20;

-- 발송/스킵 로그
select id, queue_id, status, error_code, created_at
from public.makeup_notification_logs
where academy_id = 'YOUR_ACADEMY_UUID'
order by created_at desc
limit 20;

-- 동의 없는 학생은 트리거에서 큐에 안 들어감 (샘플 확인)
select so.id, sbi.notification_consent
from public.session_overrides so
join public.student_basic_info sbi on sbi.student_id = so.student_id
where so.id = 'YOUR_OVERRIDE_UUID';
```

## 체크리스트

- [ ] 동의 끈 학생: 큐에 행이 없거나(트리거), 워커에서 `skipped`.
- [ ] `replacement_class_datetime`의 KST 날짜가 어제 이전: 큐에 안 들어감.
- [ ] 동일 `session_override_id`로 두 번 INSERT하지 않는 한 중복 발송 없음(유니크 + 로그).
- [ ] 출결 큐 `attendance_notification_queue` 처리량·출결 워커 로그에 변화 없음.

## 로컬/스테이징 1회 실행

```bash
cd gateway
MAKEUP_ALIMTALK_ENABLED=1 npm run worker:makeup:alimtalk:once
```
