-- Homework phases and event logging
-- 0: 종료, 1: 대기, 2: 수행, 3: 제출, 4: 확인

-- 1) Columns on homework_items
alter table public.homework_items
  add column if not exists phase smallint not null default 1,
  add column if not exists submitted_at timestamptz null,
  add column if not exists confirmed_at timestamptz null,
  add column if not exists waiting_at timestamptz null;

-- 2) Phase change event log table
create table if not exists public.homework_item_phase_events (
  id bigserial primary key,
  academy_id uuid not null,
  item_id uuid not null,
  phase smallint not null,
  at timestamptz not null default now(),
  actor_user_id uuid null,
  note text null,
  constraint fk_homework_item_phase_events_item
    foreign key (item_id) references public.homework_items (id) on delete cascade
);

create index if not exists idx_homework_item_phase_events_item_at
  on public.homework_item_phase_events (item_id, at desc);

create index if not exists idx_homework_item_phase_events_academy_item_at
  on public.homework_item_phase_events (academy_id, item_id, at desc);

-- 3) RPCs for phase transitions
-- Helper to append event row
create or replace function public._append_homework_phase_event(
  p_academy_id uuid,
  p_item_id uuid,
  p_phase smallint,
  p_note text default null
) returns void
language plpgsql
security definer
as $$
begin
  insert into public.homework_item_phase_events (academy_id, item_id, phase, actor_user_id, note)
  values (p_academy_id, p_item_id, p_phase, auth.uid(), p_note);
end;
$$;

-- 제출
create or replace function public.homework_submit(
  p_item_id uuid,
  p_academy_id uuid
) returns void
language plpgsql
security definer
as $$
begin
  update public.homework_items
     set phase = 3,
         submitted_at = now(),
         updated_at = now(),
         version = coalesce(version, 1) + 1
   where id = p_item_id and academy_id = p_academy_id;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 3::smallint, null::text);
end;
$$;

-- 확인
create or replace function public.homework_confirm(
  p_item_id uuid,
  p_academy_id uuid
) returns void
language plpgsql
security definer
as $$
begin
  update public.homework_items
     set phase = 4,
         confirmed_at = now(),
         updated_at = now(),
         version = coalesce(version, 1) + 1
   where id = p_item_id and academy_id = p_academy_id;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 4::smallint, null::text);
end;
$$;

-- 대기
create or replace function public.homework_wait(
  p_item_id uuid,
  p_academy_id uuid
) returns void
language plpgsql
security definer
as $$
begin
  update public.homework_items
     set phase = 1,
         waiting_at = now(),
         updated_at = now(),
         version = coalesce(version, 1) + 1
   where id = p_item_id and academy_id = p_academy_id;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 1::smallint, null::text);
end;
$$;


