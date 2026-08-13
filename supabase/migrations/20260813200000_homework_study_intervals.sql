-- 과제 학습 시간을 "구간"으로 기록하고 학원/집을 구분한다.
--
-- 지금까지 학습 시간은 homework_items.accumulated_ms 라는 단일 누적 카운터
-- 하나뿐이라, 같은 10분이 학원에서 나온 것인지 집에서 나온 것인지 알 방법이
-- 없었다. 학생앱을 집에서도 쓰게 하려면 이 구분이 필요하다.
--
-- 설계: RPC 를 하나씩 고치는 대신 homework_items.run_start 가 켜지고 꺼지는
-- 순간을 트리거로 잡는다. 학생앱·매니저앱·M5·하원 처리 어느 경로로 들어와도
-- 구간이 자동으로 남고, 앞으로 새 RPC 가 생겨도 따로 손볼 필요가 없다.

-- ---------------------------------------------------------------------------
-- 1) 구간 테이블
-- ---------------------------------------------------------------------------
create table if not exists public.homework_study_intervals (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  item_id uuid not null references public.homework_items(id) on delete cascade,
  group_id uuid,

  started_at timestamptz not null,
  ended_at timestamptz,
  duration_ms bigint,

  -- 이 구간을 어디서 했는가. 구간을 여는 시점의 출결로 판정한다.
  location_kind text not null default 'unknown',

  -- 학생앱이 수행 중임을 알려온 마지막 시각. 앱이 죽으면 여기서 끊어 마감한다.
  last_beat_at timestamptz not null default now(),

  -- 어떻게 닫혔는가: pause(정지·단계전환) / departure(하원) / relocate(등하원 분할)
  --                 / stale(무응답 상한) / cleanup(중복 정리)
  closed_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint homework_study_intervals_location_chk
    check (location_kind in ('academy', 'home', 'unknown')),
  constraint homework_study_intervals_range_chk
    check (ended_at is null or ended_at >= started_at)
);

comment on table public.homework_study_intervals is
  '과제 수행 구간(시작~종료)과 수행 장소. homework_items.run_start 트리거가 자동 기록.';

-- 아이템당 열린 구간은 하나뿐이어야 한다.
create unique index if not exists homework_study_intervals_open_uidx
  on public.homework_study_intervals (item_id)
  where ended_at is null;

create index if not exists homework_study_intervals_student_idx
  on public.homework_study_intervals (academy_id, student_id, started_at desc);

create index if not exists homework_study_intervals_group_idx
  on public.homework_study_intervals (academy_id, group_id, started_at desc);

-- 무응답 상한 스윕용 — 열려 있는 구간만 훑는다.
create index if not exists homework_study_intervals_stale_idx
  on public.homework_study_intervals (last_beat_at)
  where ended_at is null;

alter table public.homework_study_intervals enable row level security;

drop policy if exists homework_study_intervals_member_read
  on public.homework_study_intervals;
create policy homework_study_intervals_member_read
  on public.homework_study_intervals
  for select
  to authenticated
  using (
    exists (
      select 1 from public.memberships m
      where m.academy_id = homework_study_intervals.academy_id
        and m.user_id = auth.uid()
    )
    or exists (
      select 1 from public.student_app_accounts a
      where a.user_id = auth.uid()
        and a.student_id = homework_study_intervals.student_id
    )
  );

-- ---------------------------------------------------------------------------
-- 2) 아이템별 학원/집 누적 (조회용 비정규화)
-- ---------------------------------------------------------------------------
-- 구간 테이블만으로도 합계는 낼 수 있지만, 목록 화면마다 조인하면 비싸다.
-- 구간을 닫을 때 함께 더해 둔다.
alter table public.homework_items
  add column if not exists academy_ms bigint not null default 0;
alter table public.homework_items
  add column if not exists home_ms bigint not null default 0;

comment on column public.homework_items.academy_ms is
  '학원에서 수행한 누적 시간(ms). 구간 마감 시 가산. 사이클 재분배와 무관한 실측값.';
comment on column public.homework_items.home_ms is
  '집에서 수행한 누적 시간(ms). 구간 마감 시 가산.';

-- ---------------------------------------------------------------------------
-- 3) 위치 판정
-- ---------------------------------------------------------------------------
-- 등원했고 아직 하원하지 않았으면 학원, 그 외에는 집.
-- student_app_heartbeat 의 판정과 같은 규칙을 쓴다.
create or replace function public._student_location_kind(
  p_academy_id uuid,
  p_student_id uuid,
  p_at timestamptz default now()
) returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when exists (
      select 1
      from public.attendance_records ar
      where ar.academy_id = p_academy_id
        and ar.student_id = p_student_id
        and ar.date = (p_at at time zone 'Asia/Seoul')::date
        and ar.arrival_time is not null
        and ar.arrival_time <= p_at
        and (ar.departure_time is null or ar.departure_time > p_at)
    ) then 'academy'
    else 'home'
  end;
$$;

-- ---------------------------------------------------------------------------
-- 4) 구간 열기 / 닫기
-- ---------------------------------------------------------------------------
create or replace function public._homework_close_interval(
  p_item_id uuid,
  p_at timestamptz,
  p_reason text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.homework_study_intervals%rowtype;
  v_end timestamptz;
  v_ms bigint;
begin
  select * into v_row
  from public.homework_study_intervals
  where item_id = p_item_id
    and ended_at is null
  limit 1
  for update;

  if v_row.id is null then
    return;
  end if;

  -- 마감 시점이 시작보다 앞설 수는 없다 (무응답 마감에서 시계가 꼬이는 경우 방어).
  v_end := greatest(coalesce(p_at, now()), v_row.started_at);
  v_ms := greatest(0, floor(extract(epoch from (v_end - v_row.started_at)) * 1000)::bigint);

  update public.homework_study_intervals
  set ended_at = v_end,
      duration_ms = v_ms,
      closed_reason = p_reason,
      updated_at = now()
  where id = v_row.id;

  if v_ms > 0 then
    update public.homework_items h
    set academy_ms = coalesce(h.academy_ms, 0)
          + case when v_row.location_kind = 'academy' then v_ms else 0 end,
        home_ms = coalesce(h.home_ms, 0)
          + case when v_row.location_kind = 'home' then v_ms else 0 end
    where h.id = p_item_id;
  end if;
end;
$$;

create or replace function public._homework_open_interval(
  p_item_id uuid,
  p_at timestamptz
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.homework_items%rowtype;
  v_group uuid;
begin
  select * into v_item
  from public.homework_items
  where id = p_item_id;

  if v_item.id is null or v_item.student_id is null then
    return;
  end if;

  -- 열린 구간이 남아 있으면 먼저 정리한다 (정상 흐름에서는 없어야 한다).
  perform public._homework_close_interval(p_item_id, p_at, 'cleanup');

  select gi.group_id into v_group
  from public.homework_group_items gi
  where gi.academy_id = v_item.academy_id
    and gi.homework_item_id = p_item_id
  order by gi.item_order_index, gi.id
  limit 1;

  insert into public.homework_study_intervals (
    academy_id, student_id, item_id, group_id,
    started_at, last_beat_at, location_kind
  ) values (
    v_item.academy_id, v_item.student_id, p_item_id, v_group,
    p_at, greatest(p_at, now()),
    public._student_location_kind(v_item.academy_id, v_item.student_id, p_at)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) run_start 트리거 — 모든 경로를 한 곳에서 잡는다
-- ---------------------------------------------------------------------------
create or replace function public._homework_track_run_interval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.run_start is not null then
      perform public._homework_open_interval(new.id, new.run_start);
    end if;
    return new;
  end if;

  -- 시작: null -> 값
  if old.run_start is null and new.run_start is not null then
    perform public._homework_open_interval(new.id, new.run_start);
    return new;
  end if;

  -- 정지: 값 -> null
  if old.run_start is not null and new.run_start is null then
    perform public._homework_close_interval(new.id, now(), 'pause');
    return new;
  end if;

  -- 재시작(값 -> 다른 값): 이전 구간을 옛 시작점 기준으로 닫고 새로 연다.
  if old.run_start is distinct from new.run_start then
    perform public._homework_close_interval(new.id, new.run_start, 'pause');
    perform public._homework_open_interval(new.id, new.run_start);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_homework_items_track_run on public.homework_items;
create trigger trg_homework_items_track_run
  after insert or update of run_start on public.homework_items
  for each row
  execute function public._homework_track_run_interval();

-- ---------------------------------------------------------------------------
-- 6) 등하원 시 구간 분할
-- ---------------------------------------------------------------------------
-- 집에서 타이머를 켠 채 등원하면 그 구간 전체가 '집'으로 남는다.
-- 등하원 순간에 구간을 끊고 새 위치로 다시 열어 준다.
-- 타이머(run_start·accumulated_ms)와 단계는 건드리지 않는다.
create or replace function public._homework_relocate_intervals(
  p_academy_id uuid,
  p_student_id uuid,
  p_at timestamptz
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item uuid;
  v_count integer := 0;
begin
  for v_item in
    select i.item_id
    from public.homework_study_intervals i
    join public.homework_items h on h.id = i.item_id
    where i.academy_id = p_academy_id
      and i.student_id = p_student_id
      and i.ended_at is null
      and h.run_start is not null
  loop
    perform public._homework_close_interval(v_item, p_at, 'relocate');
    perform public._homework_open_interval(v_item, p_at);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public._homework_relocate_on_attendance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 등원 확정 시에만. 하원은 별도 트리거가 타이머까지 정리한다.
  if new.arrival_time is not null
     and old.arrival_time is distinct from new.arrival_time then
    perform public._homework_relocate_intervals(
      new.academy_id,
      new.student_id,
      new.arrival_time
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_homework_relocate_on_arrival on public.attendance_records;
create trigger trg_homework_relocate_on_arrival
  after update of arrival_time on public.attendance_records
  for each row
  execute function public._homework_relocate_on_attendance();

-- ---------------------------------------------------------------------------
-- 7) 이미 돌고 있는 타이머의 구간 열기 (배포 시점 정합)
-- ---------------------------------------------------------------------------
insert into public.homework_study_intervals (
  academy_id, student_id, item_id, group_id,
  started_at, last_beat_at, location_kind
)
select
  h.academy_id,
  h.student_id,
  h.id,
  (
    select gi.group_id
    from public.homework_group_items gi
    where gi.academy_id = h.academy_id
      and gi.homework_item_id = h.id
    order by gi.item_order_index, gi.id
    limit 1
  ),
  h.run_start,
  now(),
  public._student_location_kind(h.academy_id, h.student_id, h.run_start)
from public.homework_items h
where h.run_start is not null
  and h.student_id is not null
  and h.completed_at is null
  and not exists (
    select 1
    from public.homework_study_intervals i
    where i.item_id = h.id
      and i.ended_at is null
  );

revoke all on function public._student_location_kind(uuid, uuid, timestamptz) from public;
grant execute on function public._student_location_kind(uuid, uuid, timestamptz)
  to anon, authenticated;
