-- Apple Watch 독립 APNs 출결 알림.
-- attendance_records의 등원/하원 전이를 큐에 적재하고 Edge Function을 즉시 깨운다.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

create table if not exists public.watch_push_devices (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_token text not null,
  bundle_id text not null default 'com.beleunu.yggdrasill.watchkitapp',
  environment text not null default 'development'
    check (environment in ('development', 'production', 'unknown')),
  enabled boolean not null default true,
  app_version text,
  os_version text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (device_token)
);

create index if not exists idx_watch_push_devices_academy_enabled
  on public.watch_push_devices(academy_id, enabled)
  where enabled;

alter table public.watch_push_devices enable row level security;

drop policy if exists watch_push_devices_select_own
  on public.watch_push_devices;
create policy watch_push_devices_select_own
  on public.watch_push_devices for select
  using (
    user_id = auth.uid()
    and exists (
      select 1
      from public.memberships m
      where m.academy_id = watch_push_devices.academy_id
        and m.user_id = auth.uid()
    )
  );

drop policy if exists watch_push_devices_insert_own
  on public.watch_push_devices;
create policy watch_push_devices_insert_own
  on public.watch_push_devices for insert
  with check (
    user_id = auth.uid()
    and exists (
      select 1
      from public.memberships m
      where m.academy_id = watch_push_devices.academy_id
        and m.user_id = auth.uid()
    )
  );

drop policy if exists watch_push_devices_update_own
  on public.watch_push_devices;
create policy watch_push_devices_update_own
  on public.watch_push_devices for update
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (
      select 1
      from public.memberships m
      where m.academy_id = watch_push_devices.academy_id
        and m.user_id = auth.uid()
    )
  );

grant select, insert, update on public.watch_push_devices to authenticated;

create table if not exists public.watch_push_events (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  attendance_id uuid not null references public.attendance_records(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  student_name text not null,
  event_type text not null check (event_type in ('arrival', 'departure')),
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (attendance_id, event_type, occurred_at)
);

create table if not exists public.watch_push_deliveries (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.watch_push_events(id) on delete cascade,
  device_id uuid not null references public.watch_push_devices(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'sending', 'sent', 'retry', 'failed', 'disabled')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  apns_id text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, device_id)
);

create index if not exists idx_watch_push_deliveries_pending
  on public.watch_push_deliveries(status, next_attempt_at)
  where status in ('pending', 'retry');

alter table public.watch_push_events enable row level security;
alter table public.watch_push_deliveries enable row level security;
revoke all on public.watch_push_events from anon, authenticated;
revoke all on public.watch_push_deliveries from anon, authenticated;

create or replace function public._queue_watch_attendance_event(
  p_record public.attendance_records,
  p_event_type text,
  p_occurred_at timestamptz
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_event_id uuid;
  v_student_name text;
  v_delivery_count integer := 0;
begin
  select coalesce(nullif(btrim(s.name), ''), '학생')
    into v_student_name
  from public.students s
  where s.id = p_record.student_id;

  insert into public.watch_push_events(
    academy_id,
    attendance_id,
    student_id,
    student_name,
    event_type,
    occurred_at
  ) values (
    p_record.academy_id,
    p_record.id,
    p_record.student_id,
    coalesce(v_student_name, '학생'),
    p_event_type,
    p_occurred_at
  )
  on conflict (attendance_id, event_type, occurred_at)
  do update set student_name = excluded.student_name
  returning id into v_event_id;

  insert into public.watch_push_deliveries(event_id, device_id)
  select v_event_id, d.id
  from public.watch_push_devices d
  where d.academy_id = p_record.academy_id
    and d.enabled
  on conflict (event_id, device_id) do nothing;

  get diagnostics v_delivery_count = row_count;
  if v_delivery_count > 0 then
    perform net.http_post(
      url := 'https://jkanrdxaidumlvpntudy.supabase.co/functions/v1/watch_push_send',
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object('eventId', v_event_id),
      timeout_milliseconds := 8000
    );
  end if;
end;
$$;

create or replace function public._enqueue_watch_attendance_push()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.arrival_time is not null
     and (tg_op = 'INSERT' or old.arrival_time is null) then
    perform public._queue_watch_attendance_event(
      new,
      'arrival',
      new.arrival_time
    );
  end if;
  if new.departure_time is not null
     and (tg_op = 'INSERT' or old.departure_time is null) then
    perform public._queue_watch_attendance_event(
      new,
      'departure',
      new.departure_time
    );
  end if;
  return new;
end;
$$;

revoke all on function public._queue_watch_attendance_event(
  public.attendance_records,
  text,
  timestamptz
) from public, anon, authenticated;
revoke all on function public._enqueue_watch_attendance_push()
  from public, anon, authenticated;

drop trigger if exists trg_enqueue_watch_attendance_push
  on public.attendance_records;
create trigger trg_enqueue_watch_attendance_push
after insert or update of arrival_time, departure_time
on public.attendance_records
for each row
execute function public._enqueue_watch_attendance_push();

-- 일시적인 APNs/네트워크 오류로 retry 상태가 된 delivery를 다시 깨운다.
-- 즉시 호출은 위 trigger가 담당하고, cron은 유실 방지 안전망이다.
select cron.schedule(
  'watch-push-retry',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://jkanrdxaidumlvpntudy.supabase.co/functions/v1/watch_push_send',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := '{"source":"retry_cron"}'::jsonb,
    timeout_milliseconds := 8000
  );
  $$
);
