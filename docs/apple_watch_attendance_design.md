# Apple Watch 출결 연동 설계 (v0.1, Draft)

> 목적: 선생님이 손목에서 학생을 눈으로 확인하자마자 Apple Watch로 바로 "등원/하원"을 체크하면,
> iPhone 동반 앱을 통해 기존 Supabase `attendance_records` 파이프라인에 반영되도록 한다.
> 이 문서는 **코드 변경 없이 합의용 설계도**이며, 확정되면 Phase별 마이그레이션/구현으로 이어간다.

## 0. 결정 사항 요약 (Design Inputs)

| 항목 | 결정 |
|---|---|
| 사용자 | **선생님(강사) 본인** — 학생이 아님 |
| 체크 방식 | **수동 버튼** (손목에서 학생 탭 → 등원/하원 확정) |
| 앱 구조 | **iPhone 동반 앱 + watchOS companion app** (Independent watch app 아님) |
| 인증 | 학생 인증은 **불필요**. 단, "누가 찍었는지"(선생님)는 감사 기록으로 반드시 남김 |
| 범위 | **문서/설계만 우선**, 이후 Phase로 구현 |

## 1. 현재 시스템 정합성 (As-Is)

기존 체크인 경로는 Flutter 데스크톱 앱에서 RPC 호출하는 구조다.

- 테이블: `public.attendance_records(academy_id, student_id, date(KST), class_date_time, arrival_time, departure_time, is_present, notes, created_by, updated_by, version)`
- RPC: `public.m5_record_arrival(p_academy_id, p_student_id)` / `public.m5_record_departure(...)` — `grant execute ... to authenticated` 이미 존재.
- 멀티테넌시: `public.memberships(academy_id, user_id, role in ('owner','admin','staff'))` 기반 RLS. `auth.uid()`가 해당 학원의 멤버여야 CRUD 가능.
- 후속 파이프라인: 트리거로 `attendance_notification_queue`에 등원/하원/지각 이벤트가 적재되고, Edge Function `attendance_alimtalk_send`가 비즈뿌리오 AlimTalk를 발송.

핵심 결론: **Apple Watch는 새 경로를 만드는 게 아니라, "동일한 RPC를 호출하는 또 하나의 클라이언트"가 되어야 한다.** 그래야 학부모 알림톡 등 기존 부수 효과가 자동으로 따라온다.

## 2. 목표 아키텍처 (To-Be)

```
 ┌──────────────┐   WatchConnectivity   ┌───────────────────┐   HTTPS/JWT   ┌──────────────────────┐
 │  Apple Watch │ ────────────────────▶ │ iPhone Companion  │ ────────────▶ │   Supabase (PG+RLS)  │
 │  (watchOS)   │ ◀──────────────────── │  app (SwiftUI)    │ ◀──────────── │  RPC m5_record_*     │
 └──────┬───────┘   reachable / queue   └─────────┬─────────┘   realtime    └──────────┬───────────┘
        │                                         │                                     │
        │  Standalone fallback (LTE/Wi-Fi)        │  Background refresh / Push          │  attendance_notification_queue
        └─────────── URLSession ──────────────────┘  (remote + silent)                  └─▶ attendance_alimtalk_send
```

### 2.1 설계 원칙
1. **"iPhone-必須, Watch-forward"** — 기본 경로는 Watch → iPhone → Supabase. **iPhone이 근처에 없거나 꺼져 있으면 체크는 iPhone 복귀 시까지 로컬 큐에 대기**(Watch LTE 직전송 미지원).
2. **RPC는 바꾸지 않는다.** Watch/iPhone 앱은 기존 `m5_record_arrival/m5_record_departure`를 호출한다. 새 필드가 필요하면 "별도 테이블(`attendance_entry_audit`)"에 기록해 기존 스키마 파급을 최소화.
3. **멱등성(Idempotency)**: Watch 쪽은 연결이 끊길 수 있으므로, 각 체크인 이벤트는 `client_event_id (UUID)`를 들고 간다. 동일 ID가 재전송돼도 DB는 1회만 반영.
4. **감사(Audit)**: 누가(어떤 선생님 user_id), 어떤 기기(watch/phone serial hash)에서, 어떤 경로(watch_direct / via_phone / manual_retry)로 찍었는지 항상 기록.
5. **오프라인 우선**: Watch의 로컬 큐 → iPhone의 로컬 큐 → Supabase 순서. 중간에 끊기면 다음 reachable 시 드레인.

### 2.2 컴포넌트 역할

| 컴포넌트 | 책임 |
|---|---|
| watchOS App | 출석부 UI, 로컬 큐, `WCSession.sendMessage` 또는 `transferUserInfo` 로 iPhone에 전달. **네트워크 직접 호출 안 함.** |
| iPhone Companion (SwiftUI) | 로그인(Supabase Auth), 학생 목록/수업 스냅샷 캐시, Watch 큐 수신, Supabase RPC 호출, Realtime 구독으로 데스크톱 Flutter 변경사항 실시간 반영. |
| Supabase | 기존 RPC 재사용 + 감사 테이블 신규 + `device_pairings` 테이블 신규. RLS는 `memberships` 기반 유지. |
| Flutter 데스크톱 (`apps/yggdrasill`) | 관리자 설정 화면에서 "모바일 기기 페어링" UI 신설. 출결 리스트는 realtime으로 자동 갱신. |

## 3. 인증 & 기기 페어링 모델

학생 인증은 없애되, 선생님 본인 인증과 "이 iPhone이 우리 학원 것"이라는 기기 등록은 **반드시 남긴다.** (잃어버린 폰으로 출결 조작되는 사고 방지)

### 3.1 선생님 인증
- **Supabase Auth 이메일/비밀번호** 그대로 사용. 데스크톱 Flutter와 동일 계정으로 iPhone 앱에 로그인.
- iPhone 앱은 로그인 후 JWT를 **Keychain (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)** 에 저장.
- 생체인증(Face ID) 재확인: 출결 탭 진입 시 1일 1회 Face ID, 또는 앱 백그라운드 5분 초과 시 재인증. (`LocalAuthentication` 프레임워크)

### 3.2 기기 페어링 (신규)
- 신규 테이블 `public.teacher_devices`를 두고, iPhone 앱이 최초 로그인 시 자기 자신을 등록.
- 관리자는 Flutter 데스크톱의 "설정 > 모바일 기기" 화면에서 등록된 기기 목록을 보고 **승인/해제**할 수 있음. 승인되지 않은 기기는 `m5_record_*`에 해당하는 새 래퍼 RPC에서 거부.

```
[iPhone 최초 로그인]
   │
   ├─ register_teacher_device(device_uuid, model, os_version)
   │      → row 생성: status='pending'
   │
[관리자 데스크톱]
   │
   └─ 기기 목록에서 "승인" → status='active'
         (승인 없이는 출결 RPC 호출 실패)
```

- Watch는 별도 등록하지 않는다. iPhone에 페어링된 Watch는 iPhone의 device row를 상속한다 (WCSession으로 자동 연결).

### 3.3 권한 규칙
- `role in ('owner','admin','staff')` 모두 출결 체크 가능 (학원 운영 현실 고려).
- 다만 `teacher_devices.status='active'`인 기기에서 온 요청만 허용.

## 4. DB 스키마 변경안

> 실제 migration 파일은 Phase 2에서 `supabase/migrations/2026xxxx_apple_watch_attendance.sql`로 추가한다. 여기서는 **정의만.**

### 4.1 신규 테이블 `public.teacher_devices`

```sql
create table public.teacher_devices (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  -- 기기 식별
  device_uuid text not null,                 -- iOS identifierForVendor
  platform text not null check (platform in ('ios')),  -- watchOS는 iPhone 페어링에 묶여 등록하지 않음
  model text,                                 -- "iPhone15,2"
  os_version text,
  app_version text,
  -- 페어링 상태
  status text not null default 'pending' check (status in ('pending','active','revoked')),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  revoked_at timestamptz,
  last_seen_at timestamptz,
  push_token text,                           -- APNs device token (optional)
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (academy_id, device_uuid, user_id)
);

alter table public.teacher_devices enable row level security;

-- 본인은 자신의 기기 생성 가능, 본인 기기/같은 학원 기기 조회 가능
create policy teacher_devices_self_insert on public.teacher_devices
  for insert with check (
    user_id = auth.uid() and
    exists (select 1 from public.memberships m where m.academy_id = teacher_devices.academy_id and m.user_id = auth.uid())
  );

create policy teacher_devices_select on public.teacher_devices
  for select using (
    exists (select 1 from public.memberships m where m.academy_id = teacher_devices.academy_id and m.user_id = auth.uid())
  );

-- 승인/해제는 owner/admin만
create policy teacher_devices_admin_update on public.teacher_devices
  for update using (
    exists (select 1 from public.memberships m
            where m.academy_id = teacher_devices.academy_id
              and m.user_id = auth.uid()
              and m.role in ('owner','admin'))
  );
```

### 4.2 신규 테이블 `public.attendance_entry_audit`

기존 `attendance_records`를 더럽히지 않고, **한 row당 여러 체크 시도**를 원자적으로 기록한다. (예: Watch에서 등원 오터치 → 3분 뒤 Phone에서 하원 실수 → 재수정. 이 모든 시도 추적)

```sql
create table public.attendance_entry_audit (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  attendance_id uuid references public.attendance_records(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  user_id uuid not null,                    -- 누가 찍었나 (선생님)
  device_id uuid references public.teacher_devices(id),
  client_event_id text not null,            -- 멱등 키, 앱에서 생성한 UUID
  event_type text not null check (event_type in ('arrival','departure','undo_arrival','undo_departure','note')),
  event_source text not null check (event_source in ('via_phone','phone_only','flutter_desktop','api')),
  client_recorded_at timestamptz not null,  -- Watch/Phone이 로컬에서 찍은 시각
  server_recorded_at timestamptz not null default now(),
  latency_ms integer,                        -- server - client (진단용)
  payload jsonb,                             -- 원본 payload 백업
  unique (client_event_id)
);

create index on public.attendance_entry_audit(academy_id, student_id, server_recorded_at desc);

alter table public.attendance_entry_audit enable row level security;

create policy attendance_entry_audit_select on public.attendance_entry_audit
  for select using (
    exists (select 1 from public.memberships m where m.academy_id = attendance_entry_audit.academy_id and m.user_id = auth.uid())
  );

create policy attendance_entry_audit_insert on public.attendance_entry_audit
  for insert with check (
    user_id = auth.uid() and
    exists (select 1 from public.memberships m where m.academy_id = attendance_entry_audit.academy_id and m.user_id = auth.uid())
  );
```

### 4.3 신규 RPC `public.mobile_record_attendance`

Apple Watch/iPhone 앱이 **단 하나의 엔드포인트로** 등/하원/취소를 보낼 수 있게 하는 래퍼.

```sql
create or replace function public.mobile_record_attendance(
  p_academy_id   uuid,
  p_student_id   uuid,
  p_event_type   text,                       -- 'arrival' | 'departure' | 'undo_arrival' | 'undo_departure'
  p_client_event_id text,                    -- 멱등 키
  p_client_recorded_at timestamptz,          -- 손목에서 찍힌 시각
  p_device_id    uuid default null,
  p_source       text default 'via_phone',
  p_payload      jsonb default '{}'::jsonb
) returns table(attendance_id uuid, already_processed boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dev_status text;
  v_existing   uuid;
  v_att_id     uuid;
begin
  -- 1) 멤버십 체크 (RLS는 security definer면 우회되므로 수동 체크 필수)
  if not exists (select 1 from public.memberships m
                 where m.academy_id = p_academy_id and m.user_id = auth.uid()) then
    raise exception 'not a member of academy' using errcode = '42501';
  end if;

  -- 2) 기기 승인 상태 확인
  if p_device_id is not null then
    select status into v_dev_status from public.teacher_devices where id = p_device_id;
    if v_dev_status is distinct from 'active' then
      raise exception 'device not active' using errcode = '42501';
    end if;
  end if;

  -- 3) 멱등 처리 (동일 client_event_id 이미 있으면 early return)
  select attendance_id into v_existing
    from public.attendance_entry_audit
   where client_event_id = p_client_event_id;
  if found then
    return query select v_existing, true;
    return;
  end if;

  -- 4) 이벤트별 RPC 위임
  if p_event_type = 'arrival' then
    perform public.m5_record_arrival(p_academy_id, p_student_id);
  elsif p_event_type = 'departure' then
    perform public.m5_record_departure(p_academy_id, p_student_id);
  elsif p_event_type = 'undo_arrival' then
    update public.attendance_records
       set arrival_time = null,
           is_present = (departure_time is not null)
     where academy_id = p_academy_id and student_id = p_student_id
       and date = (now() at time zone 'Asia/Seoul')::date;
  elsif p_event_type = 'undo_departure' then
    update public.attendance_records
       set departure_time = null
     where academy_id = p_academy_id and student_id = p_student_id
       and date = (now() at time zone 'Asia/Seoul')::date;
  else
    raise exception 'unknown event_type %', p_event_type using errcode = '22023';
  end if;

  -- 5) 방금 만든/업데이트된 attendance row 찾기
  select id into v_att_id from public.attendance_records
   where academy_id = p_academy_id and student_id = p_student_id
     and date = (now() at time zone 'Asia/Seoul')::date
   limit 1;

  -- 6) audit 기록
  insert into public.attendance_entry_audit(
    academy_id, attendance_id, student_id, user_id, device_id,
    client_event_id, event_type, event_source,
    client_recorded_at, payload,
    latency_ms
  ) values (
    p_academy_id, v_att_id, p_student_id, auth.uid(), p_device_id,
    p_client_event_id, p_event_type, coalesce(p_source, 'via_phone'),
    p_client_recorded_at, coalesce(p_payload, '{}'::jsonb),
    extract(epoch from (now() - p_client_recorded_at))::int * 1000
  );

  return query select v_att_id, false;
end $$;

grant execute on function public.mobile_record_attendance(uuid, uuid, text, text, timestamptz, uuid, text, jsonb) to authenticated;
```

### 4.4 신규 RPC `public.register_teacher_device`

```sql
create or replace function public.register_teacher_device(
  p_academy_id uuid,
  p_device_uuid text,
  p_platform text,
  p_model text,
  p_os_version text,
  p_app_version text,
  p_push_token text default null
) returns uuid
language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if not exists (select 1 from public.memberships m where m.academy_id = p_academy_id and m.user_id = auth.uid()) then
    raise exception 'not a member of academy' using errcode='42501';
  end if;

  insert into public.teacher_devices(academy_id, user_id, device_uuid, platform, model, os_version, app_version, push_token, status)
  values (p_academy_id, auth.uid(), p_device_uuid, p_platform, p_model, p_os_version, p_app_version, p_push_token, 'pending')
  on conflict (academy_id, device_uuid, user_id) do update
    set os_version = excluded.os_version,
        app_version = excluded.app_version,
        push_token = excluded.push_token,
        last_seen_at = now(),
        updated_at = now()
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.register_teacher_device(uuid, text, text, text, text, text, text) to authenticated;
```

## 5. 클라이언트 단 설계

### 5.1 iOS 프로젝트 구조 (신규)

현재 `apps/` 밑에 `yggdrasill`(Flutter), `yggdrasill_manager`(Flutter), `survey-web`(React)이 있다.
네이티브 iOS 코드를 Flutter 앱 내부 `ios/` 에 끼워넣기보다는, **독립 프로젝트로 분리**하는 것을 권장:

```
apps/
├─ yggdrasill/                  (기존 Flutter 데스크톱)
├─ yggdrasill_manager/          (기존)
├─ survey-web/                  (기존)
└─ yggdrasill_mobile_ios/       ⟵ 신규 (Xcode workspace)
    ├─ Yggdrasill.xcodeproj
    ├─ YggdrasillApp/           (iPhone 타겟, SwiftUI)
    ├─ YggdrasillWatch/         (watchOS App)
    ├─ YggdrasillWatchExtension/
    └─ Shared/                  (공용 모델/Supabase 클라이언트)
```

이유:
- Flutter 앱은 macOS/Windows/web이 메인이라, iOS 빌드 체인을 섞으면 Windows 개발 머신에서 불필요한 복잡도가 커짐.
- Watch 앱은 SwiftUI + `WatchConnectivity` 가 필수라 어차피 네이티브.
- Supabase Swift SDK (`supabase-swift`) 를 이용해 RPC/Realtime을 깔끔하게 구현 가능.

### 5.2 watchOS 앱 화면 구성

최소 화면 3개:
1. **Home (오늘의 수업 리스트)** — 현재 수업 중인 학생들을 리스트. 각 셀에 학생명 + 상태(아직, 등원, 하원) + 큰 탭 영역.
2. **Student Detail** — 탭 시 이 화면. "등원 등록 / 하원 등록 / 취소" 버튼. 햅틱 피드백.
3. **Queue Status** — 전송 대기 큐 수와 마지막 전송 시각.

탭 시 동작 (시나리오: "학생 홍길동 등원"):
1. `UUID`로 `client_event_id` 생성 → 로컬 SQLite 큐에 `(student_id, event_type, client_event_id, client_recorded_at=Date())` 저장.
2. `WCSession.default.isReachable == true` 이면 `sendMessage(_:replyHandler:)` 로 iPhone에 전달 + 큐에서 제거.
3. `isReachable == false` 이면 `transferUserInfo(_:)` 로 백그라운드 전송(순차 보장). iPhone이 받으면 Supabase에 POST, 완료시 Watch에 ack.
4. ack 수신 시 로컬 큐에서 제거. 실패 시 다음 reachable 때 재시도.
5. **iPhone이 계속 꺼져있으면 큐에 누적되며, iPhone 복귀 시 FIFO 드레인.** (Watch 직접 네트워크 호출은 지원하지 않음)

Home 화면 UI 지침:
- 상단 고정 **"반 선택 피커"** 1개 (예: "고1 수학A"). 선생님이 담당하는 반만 나열.
- 학생 수 50명까지는 한 화면 스크롤로 충분, 스크롤 속도 개선을 위해 Digital Crown 대응.
- **검색창 없음** — watchOS 한글 자판 미지원. "수업 없는 학생 수동 등록"은 iPhone 앱에서만.

### 5.3 iPhone 동반 앱 역할

- **로그인 & 페어링**: Supabase Auth 로그인 → `memberships` 첫 행을 `active_academy_id`로 고정 → `register_teacher_device` 호출 → 승인 대기 안내. (멀티 학원 전환 UI 없음)
- **오늘의 수업 스냅샷 캐시**: 홈 진입 시 `select * from m5_students_today(p_academy_id)` 류(존재)의 결과를 Watch에 `updateApplicationContext(_:)` 로 복제. Watch는 네트워크 없이도 UI 표시.
- **수업 없는 날 출석 (수동 등록)**: iPhone 앱에서만 제공되는 **"예외 등록"** 탭. 학생 전체 검색(한글 타이핑 가능) → 등원 기록. Watch에서는 불가능.
- **큐 컨슈머**: Watch에서 온 이벤트를 `mobile_record_attendance` RPC로 전송. 실패 시 지수 백오프로 재시도 큐.
- **Realtime 구독**: `attendance_records` 채널 subscribe → 다른 기기/데스크톱에서 변경된 출결 상태를 즉시 반영 → Watch에도 push.
- **Silent push**: `attendance_records` 가 외부에서 바뀌면 Edge Function이 APNs silent push → iPhone이 백그라운드로 일어나 Watch context 업데이트.

### 5.4 Flutter 데스크톱 변경

- **"설정 > 모바일 기기 관리"** 화면 신설
  - `teacher_devices` 리스트, status 토글, 최종 접속 시각 표시.
  - 마지막 체크인 출처 확인 (디버깅용)
- **출결 리스트 행에 "출처 뱃지"** — `attendance_entry_audit` 최신 row의 `event_source` 를 가져와 "watch", "phone", "pc" 배지로 표시. 이상 감지 시 관리자가 즉시 알 수 있음.
- Realtime은 기존 `0038_realtime_publication_attendance.sql` 구독 그대로.

## 6. 동기화 / 오프라인 / 충돌 처리

### 6.1 이벤트 순서 보장
`transferUserInfo` 는 **순차 큐**를 보장하므로, Watch→Phone 구간은 순서가 꼬이지 않는다.
Phone→Supabase 구간은 네트워크 실패 시에도 **동일 `client_event_id`** 로 재시도 → DB에서 멱등 차단.

### 6.2 동시성 충돌

| 시나리오 | 처리 |
|---|---|
| 데스크톱과 Watch가 같은 초에 등원 찍음 | `m5_record_arrival` 은 `arrival_time = coalesce(arrival_time, now())`, 즉 선착순만 반영. audit에는 두 이벤트 모두 남음. |
| Watch에서 등원 찍고 바로 취소 | `undo_arrival` → `arrival_time=null`. 이 사이 알림톡 queue에 이미 떨어졌다면 `attendance_notification_queue` 를 추가로 처리해야 함 → 별도 트리거에서 `status='skipped'` 업데이트 (Phase 2 이슈). |
| Phone 꺼진 상태에서 Watch가 "등원" 2번 탭 | Watch UI에서 같은 학생 버튼은 한번 찍으면 3초 debounce + "이미 등원" 표시로 block. |

### 6.3 네트워크 단절
- Watch: 로컬 SQLite(`attendance_queue`) 사용. 영속 큐 전략.
- Phone: 동일하게 `attendance_queue` 테이블 (CoreData) 사용.
- 전송 정책: 온라인 전환 시 FIFO 드레인. 실패 시 지수 백오프 (2s, 5s, 15s, 60s, 300s, max 30min).
- 사용자에게 표시: 메인 화면 상단에 "대기 중 N건" 표시.

## 7. 보안 & 개인정보

1. **JWT 저장**: Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
2. **Face ID 재확인**: 출결 첫 사용/백그라운드 5분 초과 시 필수.
3. **device revocation**: 관리자가 `revoked` 처리하면, 다음 RPC 호출부터 즉시 차단. 앱은 401 받으면 로그아웃 처리.
4. **학생 개인정보는 Watch에 오래 저장하지 않음**: 단지 `student_id + display_name (이름 3자)` 만 캐시. 전체 PII는 iPhone에만.
5. **RLS 보강**: `attendance_records` 의 기존 정책을 유지하되, 애플 워치에서 들어오는 요청도 같은 사용자 JWT이므로 그대로 통과. `mobile_record_attendance` 내부에서 기기 승인 상태 추가 확인.
6. **로그**: `attendance_entry_audit.payload` 에 민감 정보(PII) 저장 금지. 원본 payload 대신 디버깅 메타만.

## 8. 알림톡 파이프라인과의 관계

기존 `attendance_alimtalk_send` 는 `attendance_records.arrival_time/departure_time` 변화를 트리거로 queue 를 생성한다 (`20260204090000_attendance_alimtalk_queue.sql`).

Apple Watch 경로도 **동일 RPC를 거치므로 별도 작업 없이 학부모 알림이 자동 발송된다.** ← 이게 이 설계의 가장 큰 이점.

단, 다음 edge case만 확인:
- `undo_arrival` 시 이미 queue 에 `pending` 이 있다면 `skipped` 로 처리. (Phase 2 SQL 추가)
- Watch에서 테스트 모드 토글이 있으면 `mobile_record_attendance` 에 `p_payload -> 'test'` 플래그 포함 → 트리거가 이걸 보고 queue enqueue 생략.

## 9. Phase 별 롤아웃 계획

| Phase | 목표 | 산출물 |
|---|---|---|
| **P0. 설계 합의** (지금) | 이 문서 리뷰 & 승인 | `docs/apple_watch_attendance_design.md` |
| **P1. 백엔드 스켈레톤** | `teacher_devices`, `attendance_entry_audit`, `register_teacher_device`, `mobile_record_attendance` 마이그레이션 | 새 migration 파일 1개 + Flutter "모바일 기기 관리" 화면 |
| **P2. iPhone 앱 MVP** | 로그인 → 기기 등록 → 오늘의 수업 → 출석 체크 (Watch 없이) | `apps/yggdrasill_mobile_ios/YggdrasillApp` |
| **P3. watchOS 앱** | WatchConnectivity 기반 etc. | `YggdrasillWatch` |
| **P4. 오프라인 큐 & Realtime** | Watch 큐 드레인, 실시간 양방향 반영 | 통합 테스트 |
| **P5. 보안 하드닝** | Face ID, revocation, APNs silent push | 배포 준비 |
| **P6. Pilot** | 단일 학원 시범 사용 | 피드백 문서 |

## 10. 확정 사항 (Resolved Decisions, 2026-04-21)

| 항목 | 결정 |
|---|---|
| **1. 학원 소속** | 선생님은 **단일 학원**만 소속. Watch에 학원 전환 UI 불필요. iPhone 앱도 로그인 시 첫 membership을 자동 선택. |
| **2. 학생 검색 UI** | **스크롤만 제공**, 검색 보류. (watchOS 한글 자판 미지원, 음성검색은 별도 복잡도) 단, **"수업 없는 날 온 학생" 등록 케이스는 Phase 2 이후 재검토**. |
| **3. 자동 하원 처리** | **도입하지 않음.** 하원은 반드시 선생님이 직접 Watch/iPhone/PC에서 탭. → 서버 크론 신규 추가 없음. 기존 정책 유지. |
| **4. Apple Developer Program** | **아직 준비 안 됨.** → 별도 `docs/apple_developer_onboarding.md` 단계별 가이드 작성. |
| **5. Watch 단독(LTE) 운영** | **지원하지 않음.** iPhone이 근처에 있을 때만 작동. → Watch 직접 네트워크 폴백 경로(`event_source='watch_direct'`) 제거. |

### 10.1 확정 사항이 설계에 미친 변경점 (Delta)

- **§2.2 컴포넌트 역할 "Watch 폴백 URLSession" 삭제** — Watch는 iPhone과의 `WCSession`만 사용.
- **§4.2 `attendance_entry_audit.event_source` CHECK 제약에서 `'watch_direct'` 제거.**
  → 허용값: `'via_phone' | 'phone_only' | 'flutter_desktop' | 'api'`.
- **§5.2 watchOS 화면에서 "LTE 직전송" 시나리오 삭제** — 오프라인이면 iPhone 복귀 대기만.
- **§5.3 iPhone Companion "current academy" 개념 단순화** — `memberships` 중 첫 행을 고정 사용, 멀티 학원 전환 UI 없음.
- **§5.2 Watch UI에 "검색"/"필터" 제거**, 대신 **반(class) 필터만** 단일 피커로 제공(선생님이 보통 한 반만 담당하는 가정).
- **§6 오프라인 큐 전략은 유지** (Watch↔Phone 간 전송 실패 대비용, 네트워크 복귀는 Phone 쪽에서만 발생).

## 11. Apple Developer 계정/빌드 환경 준비

Phase 2 착수 전 필수. **별도 문서**를 참고:

- [`docs/apple_developer_onboarding.md`](./apple_developer_onboarding.md) — 비개발자도 복붙 수준으로 따라할 수 있는 단계별 가이드 (Apple ID → Developer Program 가입 → Xcode 설치 → Team/Bundle ID 설정 → APNs 키 생성 → TestFlight 배포).

## 부록 A. 시퀀스 다이어그램 (Text)

### A.1 정상 등원

```
선생님        Watch               iPhone             Supabase
  │            │                    │                   │
  │ (학생탭)   │                    │                   │
  │──────────▶│ 생성 client_event_id│                   │
  │            │ enqueue 로컬 큐     │                   │
  │            │─ sendMessage ─────▶│                   │
  │            │◀── ack ─────────── │ Queue drain       │
  │            │                    │── RPC call ──────▶│ mobile_record_attendance
  │            │                    │                   │  └ m5_record_arrival
  │            │                    │                   │  └ audit insert
  │            │                    │                   │  └ queue enqueue (alimtalk)
  │            │                    │◀── OK ────────────│
  │            │◀── 완료 업데이트 ── │                   │
  │            │                    │                   │ (Edge Function later)
  │            │                    │                   │──▶ Bizppurio AlimTalk
```

### A.2 오프라인 → 복구

```
Watch (LTE 없음) ─ 4건 enqueue ─ iPhone OFF ─ 15분 후 iPhone ON
    │                                             │
    │─ transferUserInfo (4건 FIFO) ──────────────▶│
    │                                             │ drain 1건
    │                                             │─ RPC ──▶ Supabase (성공)
    │                                             │ drain 2건
    │                                             │─ RPC ──▶ 네트워크 에러
    │                                             │ 재시도 (지수 백오프)
    │                                             │─ RPC ──▶ 성공
    │                                             │ ...
    │◀── 4건 모두 ack ────────────────────────────│
```

## 부록 B. 관련 기존 파일

- `supabase/migrations/0020_w5_w6_w7.sql` — `attendance_records` 원본
- `supabase/migrations/0059_m5_arrival_departure_rpcs.sql` — `m5_record_arrival/departure`
- `supabase/migrations/0060_attendance_kst_and_defaults.sql` — KST 보정, 트리거
- `supabase/migrations/20260204090000_attendance_alimtalk_queue.sql` — 알림톡 큐
- `supabase/functions/attendance_alimtalk_send/index.ts` — 비즈뿌리오 발송 Edge Function
- `docs/attendance_alimtalk_setup.md` — 알림톡 운영 가이드

---

_초안 작성: 2026-04-21. 검토 후 P1 마이그레이션 착수 예정._
