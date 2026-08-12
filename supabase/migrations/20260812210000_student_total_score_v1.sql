-- 20260812210000: 총점(total score) v1
--
-- 총점 = 출석 40% + 과제 60% 가중 평균.
-- 과제 근거(이벤트)가 없으면 총점을 계산하지 않고 null을 반환한다(앱에서 안내 문구 표시).
--
-- 구조
--  1) _attendance_score_all_v1  : 학원 전체 학생의 출석 점수(기존 v4.1 규칙을 헬퍼로 추출)
--  2) _homework_score_all_v1    : 학원 전체 학생의 과제 점수(학습앱 homework_score_v1 미러)
--  3) student_get_attendance_score_v1 : 기존 RPC를 헬퍼 기반 래퍼로 재작성(출력 컬럼 동일)
--  4) student_get_total_score_v1 : 학생앱용 총점 + 구성요소 + 순위
--
-- 주의: 과제 점수는 학습앱 Dart(HomeworkScoreService)와 SQL 두 곳에 존재한다.
-- 출석 점수도 이미 같은 구조이므로 동일 패턴을 따른다. 한쪽을 바꾸면 반드시 양쪽을
-- 같이 바꿔야 한다(docs/assessment/scoring_migrations/20260812_009_total_score_v1.md).

-- 1) 출석 점수 헬퍼 --------------------------------------------------------------

create or replace function public._attendance_score_all_v1(p_academy_id uuid)
returns table(
  student_id uuid,
  score100 double precision,
  absence_rate double precision,
  makeup_rate double precision,
  late_rate double precision,
  absence_band integer,
  total_weight double precision,
  insufficient_evidence boolean,
  rank integer,
  cohort_size integer
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
    now() as now_ts,
    (date_trunc('day', now() at time zone 'Asia/Seoul')
      at time zone 'Asia/Seoul')::date as today
),
cohort as (
  select s.id as student_id
  from public.students s
  where s.academy_id = p_academy_id
),
thresholds as (
  select
    c.student_id,
    greatest(coalesce(spi.lateness_threshold, 10), 0)::integer as thresh
  from cohort c
  left join public.student_payment_info spi
    on spi.academy_id = p_academy_id
   and spi.student_id = c.student_id
),
att_events as (
  select
    ar.student_id,
    exp(
      -p.ln2 * (
        greatest(extract(epoch from (p.now_ts - ar.class_date_time)), 0) / 86400.0
      ) / p.half_life
    ) as w,
    case
      when coalesce(ar.is_present, false)
        or ar.arrival_time is not null
        or ar.departure_time is not null
      then
        case
          when ar.arrival_time is not null
            and ar.arrival_time > (
              ar.class_date_time + make_interval(mins => t.thresh)
            )
          then 'late'
          else 'present'
        end
      when (
        coalesce(ar.is_planned, false) = false
        and coalesce(ar.is_present, false) = false
        and ar.arrival_time is null
        and ar.departure_time is null
      )
      or (
        coalesce(ar.is_planned, false) = true
        and coalesce(ar.is_present, false) = false
        and ar.arrival_time is null
        and ar.departure_time is null
        and (ar.class_date_time at time zone 'Asia/Seoul')::date < p.today
      )
      then 'absent'
      else 'ignore'
    end as kind
  from public.attendance_records ar
  join thresholds t on t.student_id = ar.student_id
  cross join params p
  where ar.academy_id = p_academy_id
    and ar.class_date_time is not null
    and ar.class_date_time <= p.now_ts
),
att_agg as (
  select
    e.student_id,
    coalesce(sum(e.w) filter (where e.kind in ('present', 'late', 'absent')), 0)
      as total_weight,
    coalesce(sum(e.w) filter (where e.kind = 'present'), 0) as weighted_present,
    coalesce(sum(e.w) filter (where e.kind = 'late'), 0) as weighted_late,
    coalesce(sum(e.w) filter (where e.kind = 'absent'), 0) as weighted_absent
  from att_events e
  where e.kind <> 'ignore'
    and e.w > 0
    and e.w = e.w
  group by e.student_id
),
makeup_agg as (
  select
    so.student_id,
    coalesce(sum(
      exp(
        -p.ln2 * (
          greatest(
            extract(epoch from (p.now_ts - so.replacement_class_datetime)),
            0
          ) / 86400.0
        ) / p.half_life
      )
    ), 0) as weighted_makeup
  from public.session_overrides so
  cross join params p
  where so.academy_id = p_academy_id
    and so.override_type = 'replace'
    and so.reason = 'makeup'
    and so.status = 'completed'
    and so.replacement_class_datetime is not null
    and so.replacement_class_datetime <= p.now_ts
  group by so.student_id
),
raw_scores as (
  select
    c.student_id,
    coalesce(a.total_weight, 0)::double precision as total_weight,
    coalesce(a.weighted_present, 0)::double precision as weighted_present,
    coalesce(a.weighted_late, 0)::double precision as weighted_late,
    coalesce(a.weighted_absent, 0)::double precision as weighted_absent,
    coalesce(m.weighted_makeup, 0)::double precision as weighted_makeup,
    case
      when coalesce(a.total_weight, 0) > 0
      then (coalesce(a.weighted_absent, 0) / a.total_weight)::double precision
      else 0::double precision
    end as absence_rate,
    case
      when coalesce(a.total_weight, 0) > 0
      then least(
        greatest(coalesce(m.weighted_makeup, 0) / a.total_weight, 0),
        1
      )::double precision
      else 0::double precision
    end as makeup_rate,
    case
      when (coalesce(a.weighted_present, 0) + coalesce(a.weighted_late, 0)) > 0
      then (
        coalesce(a.weighted_late, 0)
        / (a.weighted_present + a.weighted_late)
      )::double precision
      else 0::double precision
    end as late_rate
  from cohort c
  left join att_agg a on a.student_id = c.student_id
  left join makeup_agg m on m.student_id = c.student_id
),
cohort_means as (
  select
    case when sum(total_weight) > 0
      then sum(weighted_absent) / sum(total_weight) else 0 end as cohort_absence,
    case when sum(total_weight) > 0
      then sum(weighted_makeup) / sum(total_weight) else 0 end as cohort_makeup,
    case when sum(weighted_present + weighted_late) > 0
      then sum(weighted_late) / sum(weighted_present + weighted_late)
      else 0 end as cohort_late
  from raw_scores
),
adjusted as (
  select
    r.student_id,
    r.total_weight,
    case
      when r.total_weight >= p.required then least(greatest(r.absence_rate, 0), 1)
      else least(greatest(
        (r.absence_rate * least(r.total_weight, p.required)
          + cm.cohort_absence * (p.required - least(r.total_weight, p.required))
        ) / p.required,
        0
      ), 1)
    end as absence_rate,
    case
      when r.total_weight >= p.required then least(greatest(r.makeup_rate, 0), 1)
      else least(greatest(
        (r.makeup_rate * least(r.total_weight, p.required)
          + cm.cohort_makeup * (p.required - least(r.total_weight, p.required))
        ) / p.required,
        0
      ), 1)
    end as makeup_rate,
    case
      when r.total_weight >= p.required then least(greatest(r.late_rate, 0), 1)
      else least(greatest(
        (r.late_rate * least(r.total_weight, p.required)
          + cm.cohort_late * (p.required - least(r.total_weight, p.required))
        ) / p.required,
        0
      ), 1)
    end as late_rate
  from raw_scores r
  cross join cohort_means cm
  cross join params p
),
scored as (
  select
    a.student_id,
    a.absence_rate,
    a.makeup_rate,
    a.late_rate,
    a.total_weight,
    (a.total_weight < p.required) as insufficient_evidence,
    case
      when a.absence_rate < 0.05 then 0
      when a.absence_rate < 0.10 then 1
      when a.absence_rate < 0.20 then 2
      when a.absence_rate < 0.30 then 3
      else 4
    end as absence_band,
    least(greatest(
      100.0
        - least(a.absence_rate * 140.0, 70.0)
        - least(a.makeup_rate * 40.0, 20.0)
        - least(a.late_rate * 10.0, 10.0),
      0
    ), 100)::double precision as score100
  from adjusted a
  cross join params p
)
select
  s.student_id,
  s.score100,
  s.absence_rate,
  s.makeup_rate,
  s.late_rate,
  s.absence_band,
  s.total_weight,
  s.insufficient_evidence,
  rank() over (
    order by
      s.absence_band asc,
      s.score100 desc,
      s.makeup_rate asc,
      s.late_rate asc
  )::integer as rank,
  count(*) over ()::integer as cohort_size
from scored s;
$$;

revoke all on function public._attendance_score_all_v1(uuid) from public;

-- 2) 과제 점수 헬퍼 --------------------------------------------------------------
-- 학습앱 HomeworkScoreService(homework_score_v1)와 동일한 파라미터/공식.
--   반감기 180일, scaleK 240
--   배정 base 0.45 (+진행률 0.20, +완료힌트 0.15)
--   검사 base 0.95 (+진행률 0.35)
--   완료 base 3.80 (+시간 최대 1.50, +검사 최대 1.00)
--   score100 = 100 * (1 - exp(-expDecayed / scaleK))

create or replace function public._homework_score_all_v1(p_academy_id uuid)
returns table(
  student_id uuid,
  score100 double precision,
  exp_raw double precision,
  exp_decayed double precision,
  event_count integer,
  assigned_count integer,
  check_count integer,
  completed_count integer,
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
    180.0::double precision as half_life,
    240.0::double precision as scale_k,
    now() as now_ts
),
events as (
  select
    a.student_id,
    'assigned'::text as kind,
    a.assigned_at as event_at,
    (
      0.45
      + (least(greatest(coalesce(a.progress, 0), 0), 150)::double precision / 150.0) * 0.20
      + case
          when lower(btrim(coalesce(a.status, ''))) = 'completed' then 0.15
          else 0.0
        end
    )::double precision as base_xp
  from public.homework_assignments a
  cross join params p
  where a.academy_id = p_academy_id
    and a.assigned_at is not null
    and a.assigned_at <= p.now_ts

  union all

  select
    c.student_id,
    'checked'::text as kind,
    c.checked_at as event_at,
    (
      0.95
      + (least(greatest(coalesce(c.progress, 0), 0), 150)::double precision / 150.0) * 0.35
    )::double precision as base_xp
  from public.homework_assignment_checks c
  cross join params p
  where c.academy_id = p_academy_id
    and c.checked_at is not null
    and c.checked_at <= p.now_ts

  union all

  select
    h.student_id,
    'completed'::text as kind,
    coalesce(
      h.completed_at, h.confirmed_at, h.submitted_at, h.updated_at, h.created_at
    ) as event_at,
    (
      3.80
      + least(
          greatest(coalesce(h.accumulated_ms, 0)::double precision / 60000.0 / 90.0, 0.0),
          1.50
        )
      + least(
          greatest(coalesce(h.check_count, 0)::double precision / 10.0, 0.0),
          1.00
        )
    )::double precision as base_xp
  from public.homework_items h
  cross join params p
  where h.academy_id = p_academy_id
    and (
      h.status = 1
      or h.completed_at is not null
      or h.confirmed_at is not null
    )
    and coalesce(
      h.completed_at, h.confirmed_at, h.submitted_at, h.updated_at, h.created_at
    ) is not null
    and coalesce(
      h.completed_at, h.confirmed_at, h.submitted_at, h.updated_at, h.created_at
    ) <= p.now_ts
),
weighted as (
  select
    e.student_id,
    e.kind,
    e.event_at,
    e.base_xp,
    e.base_xp * exp(
      -p.ln2 * (
        greatest(extract(epoch from (p.now_ts - e.event_at)), 0) / 86400.0
      ) / p.half_life
    ) as decayed_xp
  from events e
  cross join params p
  where e.base_xp > 0
    and e.student_id is not null
),
agg as (
  select
    w.student_id,
    sum(w.base_xp) as exp_raw,
    sum(w.decayed_xp) as exp_decayed,
    count(*)::integer as event_count,
    count(*) filter (where w.kind = 'assigned')::integer as assigned_count,
    count(*) filter (where w.kind = 'checked')::integer as check_count,
    count(*) filter (where w.kind = 'completed')::integer as completed_count,
    max(w.event_at) as last_event_at
  from weighted w
  group by w.student_id
)
select
  s.id as student_id,
  case
    when coalesce(a.exp_decayed, 0) <= 0 then 0::double precision
    else least(
      greatest(100.0 * (1.0 - exp(-(a.exp_decayed / p.scale_k))), 0.0),
      100.0
    )
  end as score100,
  coalesce(a.exp_raw, 0)::double precision as exp_raw,
  coalesce(a.exp_decayed, 0)::double precision as exp_decayed,
  coalesce(a.event_count, 0) as event_count,
  coalesce(a.assigned_count, 0) as assigned_count,
  coalesce(a.check_count, 0) as check_count,
  coalesce(a.completed_count, 0) as completed_count,
  a.last_event_at
from public.students s
cross join params p
left join agg a on a.student_id = s.id
where s.academy_id = p_academy_id;
$$;

revoke all on function public._homework_score_all_v1(uuid) from public;

-- 3) 기존 출석 점수 RPC을 헬퍼 기반 래퍼로 재작성(출력 컬럼/반올림 동일) ----------

create or replace function public.student_get_attendance_score_v1()
returns table(
  score100 numeric,
  rank integer,
  cohort_size integer,
  top_percent numeric,
  absence_rate numeric,
  makeup_rate numeric,
  late_rate numeric,
  insufficient_evidence boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select
    round(a.score100::numeric, 1) as score100,
    a.rank,
    a.cohort_size,
    round(((a.rank::numeric / nullif(a.cohort_size, 0)) * 100), 1) as top_percent,
    round(a.absence_rate::numeric, 4) as absence_rate,
    round(a.makeup_rate::numeric, 4) as makeup_rate,
    round(a.late_rate::numeric, 4) as late_rate,
    a.insufficient_evidence
  from public._attendance_score_all_v1(v_academy) a
  where a.student_id = v_student;
end;
$$;

revoke all on function public.student_get_attendance_score_v1() from public;
grant execute on function public.student_get_attendance_score_v1() to authenticated;

-- 4) 총점 RPC -------------------------------------------------------------------

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
      (h.event_count > 0) as hw_evidence,
      h.event_count as hw_event_count,
      case
        when a.total_weight > 0 and h.event_count > 0
        then (
          v_w_att * a.score100::numeric + v_w_hw * h.score100::numeric
        ) / (v_w_att + v_w_hw)
        else null
      end as total_score
    from public._attendance_score_all_v1(v_academy) a
    join public._homework_score_all_v1(v_academy) h
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
    'total_score_v1'::text as formula_version
  from combined c
  left join eligible e on e.student_id = c.student_id
  where c.student_id = v_student;
end;
$$;

revoke all on function public.student_get_total_score_v1() from public;
grant execute on function public.student_get_total_score_v1() to authenticated;
