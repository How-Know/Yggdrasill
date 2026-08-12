-- 20260812190000: student point system v1 (append-only ledger + derived balance)
--
-- 설계 원칙
--  1) 원장(student_point_ledger)이 유일한 진실. 잔액은 파생 캐시.
--  2) 멱등: (academy_id, student_id, season_id, kind, source_type, source_id) 유니크.
--     같은 출석/과제에 대해 물리적으로 두 번 지급 불가.
--  3) 지급은 발생 시점 값으로 확정(basis 스냅샷). 이후 점수 공식이 바뀌어도 과거 지급분 불변.
--  4) lifetime_earned(레벨용)와 balance(소비용)를 분리. 소비해도 레벨은 내려가지 않는다.
--  5) season_id를 미리 열어둔다(현재는 기본 시즌 sentinel 1개).

-- 1) 원장 ---------------------------------------------------------------------

create table if not exists public.student_point_ledger (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  season_id uuid not null default '00000000-0000-0000-0000-000000000000'::uuid,
  delta integer not null,
  kind text not null,
  source_type text not null,
  source_id text not null,
  rule_version text not null default 'point_rule_v1',
  basis jsonb not null default '{}'::jsonb,
  memo text,
  reverses_id uuid references public.student_point_ledger(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid,
  constraint chk_point_ledger_delta_nonzero check (delta <> 0),
  constraint chk_point_ledger_kind check (
    kind in (
      'earn_attendance',
      'earn_homework',
      'earn_bonus',
      'penalty',
      'spend_item',
      'adjust',
      'reversal'
    )
  ),
  constraint uq_point_ledger_source
    unique (academy_id, student_id, season_id, kind, source_type, source_id)
);

create index if not exists idx_point_ledger_student_created
  on public.student_point_ledger (academy_id, student_id, created_at desc);

create index if not exists idx_point_ledger_kind_created
  on public.student_point_ledger (academy_id, kind, created_at desc);

alter table public.student_point_ledger enable row level security;
drop policy if exists student_point_ledger_all on public.student_point_ledger;
create policy student_point_ledger_all on public.student_point_ledger for all
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_point_ledger.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_point_ledger.academy_id
      and m.user_id = auth.uid()
  )
);

-- 원장은 append-only. 정정은 삭제/수정이 아니라 reversal 거래로 남긴다.
-- (DELETE는 academies/students 캐스케이드를 막지 않기 위해 차단하지 않는다.)
create or replace function public._block_point_ledger_update()
returns trigger
language plpgsql
as $$
begin
  raise exception 'student_point_ledger is append-only: use a reversal entry instead';
end;
$$;

drop trigger if exists trg_point_ledger_block_update on public.student_point_ledger;
create trigger trg_point_ledger_block_update
before update on public.student_point_ledger
for each row execute function public._block_point_ledger_update();

-- 2) 잔액(파생 캐시) -----------------------------------------------------------

create table if not exists public.student_point_balances (
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  season_id uuid not null default '00000000-0000-0000-0000-000000000000'::uuid,
  balance integer not null default 0,
  lifetime_earned integer not null default 0,
  lifetime_spent integer not null default 0,
  entry_count integer not null default 0,
  last_event_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (academy_id, student_id, season_id)
);

create index if not exists idx_point_balances_academy_balance
  on public.student_point_balances (academy_id, balance desc);

alter table public.student_point_balances enable row level security;
drop policy if exists student_point_balances_all on public.student_point_balances;
create policy student_point_balances_all on public.student_point_balances for all
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_point_balances.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_point_balances.academy_id
      and m.user_id = auth.uid()
  )
);

create or replace function public._apply_point_ledger_to_balance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.student_point_balances as b (
    academy_id,
    student_id,
    season_id,
    balance,
    lifetime_earned,
    lifetime_spent,
    entry_count,
    last_event_at,
    updated_at
  ) values (
    new.academy_id,
    new.student_id,
    new.season_id,
    new.delta,
    greatest(new.delta, 0),
    greatest(-new.delta, 0),
    1,
    new.created_at,
    now()
  )
  on conflict (academy_id, student_id, season_id) do update
  set balance = b.balance + excluded.balance,
      lifetime_earned = b.lifetime_earned + excluded.lifetime_earned,
      lifetime_spent = b.lifetime_spent + excluded.lifetime_spent,
      entry_count = b.entry_count + 1,
      last_event_at = greatest(
        coalesce(b.last_event_at, excluded.last_event_at),
        excluded.last_event_at
      ),
      updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_point_ledger_apply_balance on public.student_point_ledger;
create trigger trg_point_ledger_apply_balance
after insert on public.student_point_ledger
for each row execute function public._apply_point_ledger_to_balance();

-- 3) 내부 지급 함수 ------------------------------------------------------------
-- 트리거/다른 security definer 함수에서만 호출한다. 클라이언트 직접 호출 금지.

create or replace function public._point_grant_internal(
  p_academy_id uuid,
  p_student_id uuid,
  p_delta integer,
  p_kind text,
  p_source_type text,
  p_source_id text,
  p_rule_version text default 'point_rule_v1',
  p_basis jsonb default '{}'::jsonb,
  p_memo text default null,
  p_actor uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_balance integer;
  v_lifetime integer;
  v_duplicate boolean := false;
begin
  if p_academy_id is null or p_student_id is null then
    return jsonb_build_object('ok', false, 'error', 'academy_and_student_required');
  end if;
  if p_delta is null or p_delta = 0 then
    return jsonb_build_object('ok', false, 'error', 'delta_required');
  end if;
  if nullif(trim(coalesce(p_source_type, '')), '') is null
     or nullif(trim(coalesce(p_source_id, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'source_required');
  end if;

  insert into public.student_point_ledger (
    academy_id,
    student_id,
    delta,
    kind,
    source_type,
    source_id,
    rule_version,
    basis,
    memo,
    created_by
  ) values (
    p_academy_id,
    p_student_id,
    p_delta,
    p_kind,
    trim(p_source_type),
    trim(p_source_id),
    coalesce(nullif(trim(coalesce(p_rule_version, '')), ''), 'point_rule_v1'),
    coalesce(p_basis, '{}'::jsonb),
    p_memo,
    p_actor
  )
  on conflict on constraint uq_point_ledger_source do nothing
  returning id into v_id;

  if v_id is null then
    v_duplicate := true;
    select l.id into v_id
    from public.student_point_ledger l
    where l.academy_id = p_academy_id
      and l.student_id = p_student_id
      and l.season_id = '00000000-0000-0000-0000-000000000000'::uuid
      and l.kind = p_kind
      and l.source_type = trim(p_source_type)
      and l.source_id = trim(p_source_id)
    limit 1;
  end if;

  select b.balance, b.lifetime_earned
    into v_balance, v_lifetime
  from public.student_point_balances b
  where b.academy_id = p_academy_id
    and b.student_id = p_student_id
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'duplicate', v_duplicate,
    'ledger_id', v_id,
    'delta', case when v_duplicate then 0 else p_delta end,
    'balance', coalesce(v_balance, 0),
    'lifetime_earned', coalesce(v_lifetime, 0)
  );
end;
$$;

revoke all on function public._point_grant_internal(
  uuid, uuid, integer, text, text, text, text, jsonb, text, uuid
) from public;

-- 4) 공개 지급 RPC(교직원 전용) -------------------------------------------------
-- 학생 계정이 임의로 포인트를 발행하지 못하도록 membership을 요구한다.

create or replace function public.point_grant_v1(
  p_academy_id uuid,
  p_student_id uuid,
  p_delta integer,
  p_kind text,
  p_source_type text,
  p_source_id text,
  p_rule_version text default 'point_rule_v1',
  p_basis jsonb default '{}'::jsonb,
  p_memo text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = v_actor
  ) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  return public._point_grant_internal(
    p_academy_id,
    p_student_id,
    p_delta,
    p_kind,
    p_source_type,
    p_source_id,
    p_rule_version,
    p_basis,
    p_memo,
    v_actor
  );
end;
$$;

revoke all on function public.point_grant_v1(
  uuid, uuid, integer, text, text, text, text, jsonb, text
) from public;
grant execute on function public.point_grant_v1(
  uuid, uuid, integer, text, text, text, text, jsonb, text
) to authenticated;

-- 5) 과제 완료 자동 지급 --------------------------------------------------------
-- 과제 품질 지표(accumulated_ms, check_count)가 DB에 있으므로 DB에서 확정한다.
-- 학습앱/학생앱 어느 경로로 완료되든 동일하게 1회만 지급된다.

create or replace function public._grant_homework_completion_points()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_minutes numeric;
  v_time_bonus numeric;
  v_check_bonus numeric;
  v_points integer;
begin
  if new.student_id is null or new.academy_id is null then
    return new;
  end if;

  v_minutes := coalesce(new.accumulated_ms, 0)::numeric / 60000.0;
  -- 90분까지 선형 가산(최대 6점). 오래 붙잡을수록 무한 가산되지 않도록 상한.
  v_time_bonus := least(v_minutes / 90.0, 1.0) * 6.0;
  -- 검사 횟수는 최대 4점까지만. 반복 검사로 무한 파밍되지 않도록 상한.
  v_check_bonus := least(coalesce(new.check_count, 0)::numeric / 5.0, 1.0) * 4.0;
  v_points := round(10.0 + v_time_bonus + v_check_bonus)::integer;

  perform public._point_grant_internal(
    new.academy_id,
    new.student_id,
    v_points,
    'earn_homework',
    'homework_item',
    new.id::text,
    'point_rule_v1',
    jsonb_build_object(
      'accumulated_ms', coalesce(new.accumulated_ms, 0),
      'minutes', round(v_minutes, 2),
      'check_count', coalesce(new.check_count, 0),
      'base', 10,
      'time_bonus', round(v_time_bonus, 2),
      'check_bonus', round(v_check_bonus, 2),
      'completed_at', new.completed_at,
      'book_id', new.book_id,
      'grade_label', new.grade_label,
      'flow_id', new.flow_id
    ),
    null::text,
    null::uuid
  );

  return new;
end;
$$;

drop trigger if exists trg_homework_items_grant_points on public.homework_items;
create trigger trg_homework_items_grant_points
after update of status on public.homework_items
for each row
when (new.status = 1 and old.status is distinct from 1)
execute function public._grant_homework_completion_points();

-- 6) 조회 RPC(요약) -------------------------------------------------------------

create or replace function public.point_summary_v1(
  p_academy_id uuid,
  p_student_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.student_point_balances%rowtype;
begin
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select * into v_row
  from public.student_point_balances b
  where b.academy_id = p_academy_id
    and b.student_id = p_student_id
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'balance', coalesce(v_row.balance, 0),
    'lifetime_earned', coalesce(v_row.lifetime_earned, 0),
    'lifetime_spent', coalesce(v_row.lifetime_spent, 0),
    'entry_count', coalesce(v_row.entry_count, 0),
    'last_event_at', v_row.last_event_at
  );
end;
$$;

revoke all on function public.point_summary_v1(uuid, uuid) from public;
grant execute on function public.point_summary_v1(uuid, uuid) to authenticated;
