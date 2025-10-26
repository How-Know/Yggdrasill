-- Device ↔ Student binding and helpers

create table if not exists public.m5_device_bindings (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null,
  device_id text not null,
  student_id uuid not null,
  active boolean not null default true,
  bound_at timestamptz not null default now(),
  unbound_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- one active binding per device
create unique index if not exists uq_m5_binding_active_device on public.m5_device_bindings(academy_id, device_id) where active;
-- optional: one active device per student
create unique index if not exists uq_m5_binding_active_student on public.m5_device_bindings(academy_id, student_id) where active;

alter table public.m5_device_bindings enable row level security;
do $$ begin
  if not exists (
    select 1 from pg_policies where schemaname='public' and tablename='m5_device_bindings' and policyname='m5_binding_select'
  ) then
    create policy m5_binding_select on public.m5_device_bindings for select using (true);
  end if;
end $$;

create or replace function public.m5_bind_device(
  p_academy_id uuid,
  p_device_id text,
  p_student_id uuid
) returns void
language plpgsql security definer set search_path=public as $$
begin
  -- close previous bindings for device and student
  update public.m5_device_bindings
  set active=false, unbound_at=now(), updated_at=now()
  where academy_id=p_academy_id and (device_id=p_device_id or student_id=p_student_id) and active=true;

  insert into public.m5_device_bindings(academy_id, device_id, student_id, active, bound_at, updated_at)
  values (p_academy_id, p_device_id, p_student_id, true, now(), now());
end; $$;

create or replace function public.m5_unbind_device(
  p_academy_id uuid,
  p_device_id text
) returns void
language plpgsql security definer set search_path=public as $$
begin
  update public.m5_device_bindings
  set active=false, unbound_at=now(), updated_at=now()
  where academy_id=p_academy_id and device_id=p_device_id and active=true;
end; $$;

create or replace function public.m5_unbind_by_student(
  p_academy_id uuid,
  p_student_id uuid
) returns void
language plpgsql security definer set search_path=public as $$
begin
  update public.m5_device_bindings
  set active=false, unbound_at=now(), updated_at=now()
  where academy_id=p_academy_id and student_id=p_student_id and active=true;
end; $$;

-- today students (basic): by student_time_blocks day_index
drop function if exists public.m5_get_students_today_basic(uuid);
create function public.m5_get_students_today_basic(
  p_academy_id uuid
) returns table(student_id uuid, name text) as $$
declare
  d int := extract(dow from now()); -- 0:Sun..6:Sat
  day_idx int := case when d=0 then 6 else d-1 end; -- 0:Mon..6:Sun
begin
  return query
  select distinct s.id, s.name
  from public.student_time_blocks b
  join public.students s on s.id = b.student_id
  where b.academy_id = p_academy_id and b.day_index = day_idx;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_bind_device(uuid, text, uuid) to anon, authenticated;
grant execute on function public.m5_unbind_device(uuid, text) to anon, authenticated;
grant execute on function public.m5_unbind_by_student(uuid, uuid) to anon, authenticated;
grant execute on function public.m5_get_students_today_basic(uuid) to anon, authenticated;



