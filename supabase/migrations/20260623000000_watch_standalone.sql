-- 20260623000000: Apple Watch 단독 동작 지원
--
-- 목표: iPhone 앱이 꺼져 있어도 Watch가 서버와 직접 통신할 수 있게 한다.
--  1) watch_snapshots: iPhone이 계산한 "오늘 출결 대상/숙제 목록" 페이로드를
--     그대로 발행해 두는 denormalized 테이블. Watch는 이걸 직접 읽는다.
--     (읽기 로직을 서버/Swift에 중복 구현하지 않기 위함)
--  2) watch_record_attendance: Watch가 특정 세션(class_date_time)에 대해
--     등원/하원을 직접 기록하는 전용 RPC.

-- =====================================================================
-- 1) watch_snapshots
-- =====================================================================
create table if not exists public.watch_snapshots (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  -- 'today_targets' | 'homework'
  kind text not null,
  -- today_targets: 'all', homework: student_id
  scope_key text not null,
  -- KST 기준 'YYYY-MM-DD'
  snapshot_date text not null,
  payload jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create unique index if not exists uq_watch_snapshots_key
  on public.watch_snapshots(academy_id, kind, scope_key, snapshot_date);
create index if not exists idx_watch_snapshots_academy
  on public.watch_snapshots(academy_id);

alter table public.watch_snapshots enable row level security;
drop policy if exists watch_snapshots_all on public.watch_snapshots;
create policy watch_snapshots_all on public.watch_snapshots for all
using (
  exists (
    select 1 from public.memberships s
    where s.academy_id = watch_snapshots.academy_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships s
    where s.academy_id = watch_snapshots.academy_id
      and s.user_id = auth.uid()
  )
);

-- iPhone(또는 Watch가 인증된 세션으로) 스냅샷을 upsert 한다.
create or replace function public.watch_upsert_snapshot(
  p_academy_id uuid,
  p_kind text,
  p_scope_key text,
  p_snapshot_date text,
  p_payload jsonb
) returns void as $$
begin
  if not exists (
    select 1 from public.memberships s
    where s.academy_id = p_academy_id and s.user_id = auth.uid()
  ) then
    raise exception 'not_a_member';
  end if;

  insert into public.watch_snapshots(
    academy_id, kind, scope_key, snapshot_date, payload, updated_at, updated_by
  ) values (
    p_academy_id, p_kind, p_scope_key, p_snapshot_date, coalesce(p_payload, '{}'::jsonb), now(), auth.uid()
  )
  on conflict (academy_id, kind, scope_key, snapshot_date)
  do update set
    payload = excluded.payload,
    updated_at = now(),
    updated_by = auth.uid();
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.watch_upsert_snapshot(uuid, text, text, text, jsonb) to authenticated;

-- =====================================================================
-- 2) watch_record_attendance
-- =====================================================================
-- Watch가 스냅샷에서 받은 정확한 class_date_time(분 단위)로 등/하원을 기록한다.
-- 동일 분(minute)의 기존 레코드가 있으면 갱신, 없으면 새로 생성한다.
create or replace function public.watch_record_attendance(
  p_academy_id uuid,
  p_student_id uuid,
  p_class_date_time timestamptz,
  p_action text,                 -- 'arrival' | 'departure'
  p_class_end_time timestamptz default null,
  p_class_name text default null,
  p_set_id uuid default null,
  p_session_type_id uuid default null
) returns void as $$
declare
  existing_id uuid;
  v_date date := (coalesce(p_class_date_time, now()) at time zone 'Asia/Seoul')::date;
begin
  if not exists (
    select 1 from public.memberships s
    where s.academy_id = p_academy_id and s.user_id = auth.uid()
  ) then
    raise exception 'not_a_member';
  end if;

  if p_action not in ('arrival', 'departure') then
    raise exception 'invalid_action';
  end if;

  select id into existing_id
    from public.attendance_records
   where academy_id = p_academy_id
     and student_id = p_student_id
     and class_date_time is not null
     and date_trunc('minute', class_date_time) = date_trunc('minute', p_class_date_time)
   order by created_at asc
   limit 1;

  if existing_id is not null then
    if p_action = 'arrival' then
      update public.attendance_records
         set arrival_time   = coalesce(arrival_time, now()),
             departure_time = null,
             is_present     = true,
             updated_at     = now()
       where id = existing_id;
    else
      update public.attendance_records
         set arrival_time   = coalesce(arrival_time, now()),
             departure_time = now(),
             is_present     = true,
             updated_at     = now()
       where id = existing_id;
    end if;
  else
    insert into public.attendance_records (
      academy_id, student_id, set_id, session_type_id,
      class_date_time, class_end_time, class_name, date,
      is_present, arrival_time, departure_time, is_planned,
      created_at, updated_at
    ) values (
      p_academy_id, p_student_id, p_set_id, p_session_type_id,
      p_class_date_time,
      coalesce(p_class_end_time, p_class_date_time + interval '1 hour'),
      coalesce(p_class_name, '수업'), v_date,
      true,
      now(),
      case when p_action = 'departure' then now() else null end,
      false,
      now(), now()
    );
  end if;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.watch_record_attendance(uuid, uuid, timestamptz, text, timestamptz, text, uuid, uuid) to authenticated;
