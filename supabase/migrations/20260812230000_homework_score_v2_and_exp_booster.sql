-- 20260812230000: 과제 점수 v2(비율 기반) + EXP 부스터
--
-- 배경
--  과제 점수 v1은 EXP 누적값에서 역산(100*(1-exp(-EXP/240)))했다. 누적값에서 상태 점수를
--  뽑으면 필연적으로 천장에 붙는다. 실측상 3개월에 94점, 반년이면 99점대로 포화되어
--  변별력이 사라지고, 과제를 1년 끊어도 90점이 유지됐다.
--
-- v2 구조 (두 층 분리)
--  1) 스탯 층(0~100): 출석 점수, 과제 점수, 총점. 누적이 아니라 "지금 얼마나 잘하고 있나".
--     과제 점수도 출석처럼 비율 기반으로 바꿔 포화를 없앤다.
--  2) EXP 층(순수 누적): 포인트 원장. 감쇠 없음. 획득량 = 기본 XP × 부스터.
--     부스터는 스탯 층(총점)에서 나온다. 성실한 학생이 같은 과제로 더 많은 EXP를 받는다.
--
-- 과제 점수 v2 요약
--  평가 단위: 과제 배정(assignment)
--  평가 대상: 완료됐거나, 기한이 지났거나, 기한 없이 배정 후 7일 경과
--            (오늘 내준 과제를 미완료로 감점하지 않기 위한 게이트. 출석 v3와 같은 사고)
--  가중치: exp(-ln2 * 경과일 / 28)   ← 기준시각 coalesce(due_at, assigned_at)
--  품질 q: 완료 1.0 / 미완료 min(0.85, 0.70*진행률 + 0.15*검사여부) / 미착수 0.0
--  비율: sum(w*q) / sum(w), 유효 가중치 8 미만이면 코호트 평균으로 베이지안 스무딩
--  점수: 비율 * 100

-- 1) 과제 점수 v2 헬퍼 -----------------------------------------------------------

create or replace function public._homework_score_all_v2(p_academy_id uuid)
returns table(
  student_id uuid,
  score100 double precision,
  ratio_raw double precision,
  ratio_adjusted double precision,
  total_weight double precision,
  evaluated_count integer,
  completed_count integer,
  partial_count integer,
  untouched_count integer,
  pending_count integer,
  insufficient_evidence boolean,
  last_event_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
with params as (
  select
    0.6931471805599453::double precision as ln2,
    28.0::double precision as half_life,
    8.0::double precision as required,
    7 as grace_days,
    0.90::double precision as fallback_ratio,
    now() as now_ts
),
checked_items as (
  select distinct c.student_id, c.homework_item_id
  from public.homework_assignment_checks c
  where c.academy_id = p_academy_id
),
graded as (
  select
    a.student_id,
    coalesce(a.due_at, a.assigned_at) as ref_at,
    (lower(btrim(coalesce(a.status, ''))) = 'completed') as is_completed,
    least(greatest(coalesce(a.progress, 0), 0), 100)::double precision as prog,
    (ck.homework_item_id is not null) as was_checked,
    (
      lower(btrim(coalesce(a.status, ''))) = 'completed'
      or (a.due_at is not null and a.due_at < p.now_ts)
      or (
        a.due_at is null
        and a.assigned_at < p.now_ts - make_interval(days => p.grace_days)
      )
    ) as evaluable
  from public.homework_assignments a
  cross join params p
  left join checked_items ck
    on ck.student_id = a.student_id
   and ck.homework_item_id = a.homework_item_id
  where a.academy_id = p_academy_id
    and a.assigned_at is not null
    and a.assigned_at <= p.now_ts
),
scored_events as (
  select
    g.student_id,
    g.ref_at,
    g.is_completed,
    g.prog,
    g.was_checked,
    exp(
      -p.ln2 * (
        greatest(extract(epoch from (p.now_ts - g.ref_at)), 0) / 86400.0
      ) / p.half_life
    ) as w,
    case
      when g.is_completed then 1.0::double precision
      else least(
        0.85::double precision,
        0.70 * (g.prog / 100.0)
          + case when g.was_checked then 0.15 else 0.0 end
      )
    end as q
  from graded g
  cross join params p
  where g.evaluable
),
pending_agg as (
  select g.student_id, count(*)::integer as pending_count
  from graded g
  where not g.evaluable
  group by g.student_id
),
agg as (
  select
    e.student_id,
    sum(e.w) as total_weight,
    sum(e.w * e.q) as weighted_q,
    count(*)::integer as evaluated_count,
    count(*) filter (where e.is_completed)::integer as completed_count,
    count(*) filter (
      where not e.is_completed and (e.prog > 0 or e.was_checked)
    )::integer as partial_count,
    count(*) filter (
      where not e.is_completed and e.prog <= 0 and not e.was_checked
    )::integer as untouched_count,
    max(e.ref_at) as last_event_at
  from scored_events e
  where e.w > 0
  group by e.student_id
),
cohort as (
  select
    case
      when sum(a.total_weight) > 0 then sum(a.weighted_q) / sum(a.total_weight)
      else (select fallback_ratio from params)
    end as ratio
  from agg a
),
base_rows as (
  select
    s.id as student_id,
    coalesce(a.total_weight, 0)::double precision as total_weight,
    case
      when coalesce(a.total_weight, 0) > 0 then a.weighted_q / a.total_weight
      else null
    end as ratio_raw,
    coalesce(a.evaluated_count, 0) as evaluated_count,
    coalesce(a.completed_count, 0) as completed_count,
    coalesce(a.partial_count, 0) as partial_count,
    coalesce(a.untouched_count, 0) as untouched_count,
    coalesce(pg.pending_count, 0) as pending_count,
    a.last_event_at,
    c.ratio as cohort_ratio,
    p.required
  from public.students s
  cross join params p
  cross join cohort c
  left join agg a on a.student_id = s.id
  left join pending_agg pg on pg.student_id = s.id
  where s.academy_id = p_academy_id
),
smoothed as (
  select
    f.*,
    least(
      greatest(
        case
          when f.total_weight >= f.required then coalesce(f.ratio_raw, 0)
          else (
            coalesce(f.ratio_raw, f.cohort_ratio) * least(f.total_weight, f.required)
            + f.cohort_ratio * (f.required - least(f.total_weight, f.required))
          ) / f.required
        end,
        0
      ),
      1
    )::double precision as ratio_adjusted
  from base_rows f
)
select
  s.student_id,
  (s.ratio_adjusted * 100.0)::double precision as score100,
  s.ratio_raw,
  s.ratio_adjusted,
  s.total_weight,
  s.evaluated_count,
  s.completed_count,
  s.partial_count,
  s.untouched_count,
  s.pending_count,
  (s.total_weight < s.required) as insufficient_evidence,
  s.last_event_at
from smoothed s;
$$;

revoke all on function public._homework_score_all_v2(uuid) from public;

-- 2) 학습앱(교직원)용 과제 점수 조회 RPC ------------------------------------------
-- 학습앱도 이 RPC를 사용해 Dart/SQL 이중 구현을 없앤다.

create or replace function public.homework_score_all_v2(p_academy_id uuid)
returns table(
  student_id uuid,
  score100 double precision,
  ratio_raw double precision,
  ratio_adjusted double precision,
  total_weight double precision,
  evaluated_count integer,
  completed_count integer,
  partial_count integer,
  untouched_count integer,
  pending_count integer,
  insufficient_evidence boolean,
  last_event_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'forbidden';
  end if;

  return query select * from public._homework_score_all_v2(p_academy_id);
end;
$$;

revoke all on function public.homework_score_all_v2(uuid) from public;
grant execute on function public.homework_score_all_v2(uuid) to authenticated;

-- 3) 부스터 산식 ----------------------------------------------------------------
-- booster = 0.6 + (총점/100) * 1.4  →  0.6 ~ 2.0
-- 근거가 없으면 1.0(중립)으로 두어 신규 학생의 적립을 막지 않는다.

create or replace function public._booster_from_total_v1(p_total double precision)
returns double precision
language sql
immutable
set search_path = public
as $$
  select case
    when p_total is null then 1.0::double precision
    else least(greatest(0.6 + (p_total / 100.0) * 1.4, 0.6), 2.0)
  end;
$$;

-- 4) 점수 캐시 ------------------------------------------------------------------
-- 과제 완료 트리거가 매번 학원 전체를 재계산하지 않도록 부스터를 캐시한다.
-- 신선도 30분. 교사가 여러 건을 연속 완료해도 갱신은 1회만 일어난다.

create table if not exists public.student_score_cache (
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  attendance_score100 double precision,
  homework_score100 double precision,
  total_score100 double precision,
  booster_input double precision,
  booster double precision not null default 1.0,
  computed_at timestamptz not null default now(),
  primary key (academy_id, student_id)
);

create index if not exists idx_student_score_cache_computed
  on public.student_score_cache (academy_id, computed_at desc);

alter table public.student_score_cache enable row level security;
drop policy if exists student_score_cache_all on public.student_score_cache;
create policy student_score_cache_all on public.student_score_cache for all
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_score_cache.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.academy_id = student_score_cache.academy_id
      and m.user_id = auth.uid()
  )
);

create or replace function public.refresh_student_score_cache_v1(p_academy_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
begin
  insert into public.student_score_cache as c (
    academy_id,
    student_id,
    attendance_score100,
    homework_score100,
    total_score100,
    booster_input,
    booster,
    computed_at
  )
  select
    p_academy_id,
    a.student_id,
    a.score100,
    h.score100,
    -- 표시용 총점: 출석/과제 근거가 모두 있을 때만.
    case
      when a.total_weight > 0 and h.evaluated_count > 0
      then (0.4 * a.score100 + 0.6 * h.score100) / (0.4 + 0.6)
      else null
    end,
    -- 부스터 입력: 총점이 없으면 출석 점수로 대체, 둘 다 없으면 null(=중립 1.0).
    case
      when a.total_weight > 0 and h.evaluated_count > 0
      then (0.4 * a.score100 + 0.6 * h.score100) / (0.4 + 0.6)
      when a.total_weight > 0 then a.score100
      else null
    end,
    public._booster_from_total_v1(
      case
        when a.total_weight > 0 and h.evaluated_count > 0
        then (0.4 * a.score100 + 0.6 * h.score100) / (0.4 + 0.6)
        when a.total_weight > 0 then a.score100
        else null
      end
    ),
    now()
  from public._attendance_score_all_v1(p_academy_id) a
  join public._homework_score_all_v2(p_academy_id) h
    on h.student_id = a.student_id
  on conflict (academy_id, student_id) do update
  set attendance_score100 = excluded.attendance_score100,
      homework_score100 = excluded.homework_score100,
      total_score100 = excluded.total_score100,
      booster_input = excluded.booster_input,
      booster = excluded.booster,
      computed_at = now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.refresh_student_score_cache_v1(uuid) from public;
grant execute on function public.refresh_student_score_cache_v1(uuid) to authenticated;

create or replace function public._booster_for_v1(
  p_academy_id uuid,
  p_student_id uuid
) returns double precision
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booster double precision;
  v_at timestamptz;
begin
  select c.booster, c.computed_at
    into v_booster, v_at
  from public.student_score_cache c
  where c.academy_id = p_academy_id
    and c.student_id = p_student_id;

  if v_booster is null or v_at is null or v_at < now() - interval '30 minutes' then
    begin
      perform public.refresh_student_score_cache_v1(p_academy_id);
      select c.booster into v_booster
      from public.student_score_cache c
      where c.academy_id = p_academy_id
        and c.student_id = p_student_id;
    exception when others then
      -- 캐시 갱신 실패가 포인트 적립을 막아서는 안 된다. 중립 배수로 진행.
      v_booster := null;
    end;
  end if;

  return coalesce(v_booster, 1.0);
end;
$$;

revoke all on function public._booster_for_v1(uuid, uuid) from public;

-- 학습앱도 트리거와 완전히 같은 부스터 값을 쓰도록 공개 RPC를 둔다.
create or replace function public.booster_for_v1(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
  booster double precision,
  booster_input double precision,
  total_score100 double precision,
  attendance_score100 double precision,
  homework_score100 double precision,
  computed_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'forbidden';
  end if;

  -- 캐시가 오래됐으면 갱신한다.
  perform public._booster_for_v1(p_academy_id, p_student_id);

  return query
  select
    c.booster,
    c.booster_input,
    c.total_score100,
    c.attendance_score100,
    c.homework_score100,
    c.computed_at
  from public.student_score_cache c
  where c.academy_id = p_academy_id
    and c.student_id = p_student_id;
end;
$$;

revoke all on function public.booster_for_v1(uuid, uuid) from public;
grant execute on function public.booster_for_v1(uuid, uuid) to authenticated;

-- 5) 과제 완료 포인트에 부스터 적용 ----------------------------------------------

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
  v_base numeric;
  v_booster numeric;
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
  v_base := 10.0 + v_time_bonus + v_check_bonus;

  v_booster := public._booster_for_v1(new.academy_id, new.student_id)::numeric;
  v_points := greatest(round(v_base * v_booster)::integer, 1);

  perform public._point_grant_internal(
    new.academy_id,
    new.student_id,
    v_points,
    'earn_homework',
    'homework_item',
    new.id::text,
    'point_rule_v2',
    jsonb_build_object(
      'accumulated_ms', coalesce(new.accumulated_ms, 0),
      'minutes', round(v_minutes, 2),
      'check_count', coalesce(new.check_count, 0),
      'base', round(v_base, 2),
      'time_bonus', round(v_time_bonus, 2),
      'check_bonus', round(v_check_bonus, 2),
      'booster', round(v_booster, 4),
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

-- 6) 총점 RPC를 과제 점수 v2 기준으로 갱신 ---------------------------------------

create or replace function public.student_get_total_score_v1()
returns table(
  total_score100 numeric,
  has_total boolean,
  attendance_score100 numeric,
  homework_score100 numeric,
  attendance_weight numeric,
  homework_weight numeric,
  attendance_evidence boolean,
  homework_evidence boolean,
  homework_event_count integer,
  rank integer,
  cohort_size integer,
  top_percent numeric,
  formula_version text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_w_att constant numeric := 0.4;
  v_w_hw constant numeric := 0.6;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with combined as (
    select
      a.student_id,
      a.score100 as att_score,
      h.score100 as hw_score,
      (a.total_weight > 0) as att_evidence,
      (h.evaluated_count > 0) as hw_evidence,
      h.evaluated_count as hw_event_count,
      case
        when a.total_weight > 0 and h.evaluated_count > 0
        then (
          v_w_att * a.score100::numeric + v_w_hw * h.score100::numeric
        ) / (v_w_att + v_w_hw)
        else null
      end as total_score
    from public._attendance_score_all_v1(v_academy) a
    join public._homework_score_all_v2(v_academy) h
      on h.student_id = a.student_id
  ),
  eligible as (
    select
      c.student_id,
      c.total_score,
      rank() over (order by c.total_score desc, c.student_id asc)::integer as rank,
      count(*) over ()::integer as cohort_size
    from combined c
    where c.total_score is not null
  )
  select
    round(c.total_score, 1) as total_score100,
    (c.total_score is not null) as has_total,
    round(c.att_score::numeric, 1) as attendance_score100,
    round(c.hw_score::numeric, 1) as homework_score100,
    v_w_att as attendance_weight,
    v_w_hw as homework_weight,
    c.att_evidence,
    c.hw_evidence,
    c.hw_event_count,
    e.rank,
    e.cohort_size,
    round(((e.rank::numeric / nullif(e.cohort_size, 0)) * 100), 1) as top_percent,
    'total_score_v2'::text as formula_version
  from combined c
  left join eligible e on e.student_id = c.student_id
  where c.student_id = v_student;
end;
$$;

revoke all on function public.student_get_total_score_v1() from public;
grant execute on function public.student_get_total_score_v1() to authenticated;

-- 7) v1 과제 점수 헬퍼 제거(더 이상 참조 없음) -----------------------------------

drop function if exists public._homework_score_all_v1(uuid);
