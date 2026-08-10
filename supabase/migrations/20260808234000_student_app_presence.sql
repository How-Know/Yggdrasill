-- 학생앱 온라인 presence (학습앱에서 M5 기기 배지처럼 표시).
-- location_kind: academy(등원중) | home(그 외)

create table if not exists public.student_app_presence (
  student_id uuid primary key references public.students(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  is_online boolean not null default true,
  last_seen timestamptz not null default now(),
  location_kind text not null default 'unknown'
    check (location_kind in ('academy', 'home', 'unknown')),
  updated_at timestamptz not null default now()
);

create index if not exists idx_student_app_presence_academy_online
  on public.student_app_presence (academy_id, is_online, last_seen desc);

alter table public.student_app_presence enable row level security;

drop policy if exists student_app_presence_staff_select on public.student_app_presence;
create policy student_app_presence_staff_select on public.student_app_presence
for select to authenticated
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = student_app_presence.academy_id
      and m.user_id = auth.uid()
  )
);

drop policy if exists student_app_presence_self_select on public.student_app_presence;
create policy student_app_presence_self_select on public.student_app_presence
for select to authenticated
using (
  exists (
    select 1
    from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.student_id = student_app_presence.student_id
      and a.academy_id = student_app_presence.academy_id
  )
);

-- Realtime
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'student_app_presence'
    ) then
      execute 'alter publication supabase_realtime add table public.student_app_presence';
    end if;
  end if;
end $$;

alter table public.student_app_presence replica identity full;

-- 등원중(오늘 Asia/Seoul, arrival 있고 departure 없음) → academy, 아니면 home
create or replace function public.student_app_heartbeat()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'Asia/Seoul')::date;
  v_at_academy boolean := false;
  v_kind text;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;

  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select exists (
    select 1
    from public.attendance_records ar
    where ar.academy_id = v_academy
      and ar.student_id = v_student
      and ar.date = v_day
      and ar.arrival_time is not null
      and ar.departure_time is null
  ) into v_at_academy;

  v_kind := case when v_at_academy then 'academy' else 'home' end;

  insert into public.student_app_presence as p (
    student_id, academy_id, user_id, is_online, last_seen, location_kind, updated_at
  ) values (
    v_student, v_academy, v_user, true, now(), v_kind, now()
  )
  on conflict (student_id) do update set
    academy_id = excluded.academy_id,
    user_id = excluded.user_id,
    is_online = true,
    last_seen = excluded.last_seen,
    location_kind = excluded.location_kind,
    updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'location_kind', v_kind,
    'last_seen', now()
  );
end;
$$;

revoke all on function public.student_app_heartbeat() from public;
grant execute on function public.student_app_heartbeat() to authenticated;

create or replace function public.student_app_presence_offline()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid;
begin
  select i.student_id into v_student from public.student_app_identity() i;
  if v_student is null then
    return;
  end if;

  update public.student_app_presence
  set is_online = false,
      updated_at = now(),
      last_seen = now()
  where student_id = v_student;
end;
$$;

revoke all on function public.student_app_presence_offline() from public;
grant execute on function public.student_app_presence_offline() to authenticated;
