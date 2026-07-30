-- 학생앱: 출결(출석) 점수 + 학원 내 상위 퍼센트
-- 학습앱 AttendanceService/DataManager v4.1 규칙과 동일하게 서버에서 계산.

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
  v_now timestamptz := now();
  v_today date := (date_trunc('day', now() at time zone 'Asia/Seoul')
                   at time zone 'Asia/Seoul')::date;
  v_ln2 constant double precision := 0.6931471805599453;
  v_half_life constant double precision := 28.0;
  v_required constant double precision := 8.0;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with cohort as (
    select s.id as student_id
    from public.students s
    where s.academy_id = v_academy
  ),
  thresholds as (
    select
      c.student_id,
      greatest(coalesce(spi.lateness_threshold, 10), 0)::integer as thresh
    from cohort c
    left join public.student_payment_info spi
      on spi.academy_id = v_academy
     and spi.student_id = c.student_id
  ),
  att_events as (
    select
      ar.student_id,
      exp(
        -v_ln2 * (
          greatest(extract(epoch from (v_now - ar.class_date_time)), 0) / 86400.0
        ) / v_half_life
      ) as w,
      case
        when coalesce(ar.is_present, false)
          or ar.arrival_time is not null
          or ar.departure_time is not null
        then
          case
            when ar.arrival_time is not null
              and ar.arrival_time > (
                ar.class_date_time
                + make_interval(mins => t.thresh)
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
          and (ar.class_date_time at time zone 'Asia/Seoul')::date < v_today
        )
        then 'absent'
        else 'ignore'
      end as kind
    from public.attendance_records ar
    join thresholds t on t.student_id = ar.student_id
    where ar.academy_id = v_academy
      and ar.class_date_time is not null
      and ar.class_date_time <= v_now
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
      and e.w = e.w -- not NaN
    group by e.student_id
  ),
  makeup_agg as (
    select
      so.student_id,
      coalesce(sum(
        exp(
          -v_ln2 * (
            greatest(
              extract(epoch from (v_now - so.replacement_class_datetime)),
              0
            ) / 86400.0
          ) / v_half_life
        )
      ), 0) as weighted_makeup
    from public.session_overrides so
    where so.academy_id = v_academy
      and so.override_type = 'replace'
      and so.reason = 'makeup'
      and so.status = 'completed'
      and so.replacement_class_datetime is not null
      and so.replacement_class_datetime <= v_now
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
        when r.total_weight >= v_required then least(greatest(r.absence_rate, 0), 1)
        else least(greatest(
          (r.absence_rate * least(r.total_weight, v_required)
            + cm.cohort_absence * (v_required - least(r.total_weight, v_required))
          ) / v_required,
          0
        ), 1)
      end as absence_rate,
      case
        when r.total_weight >= v_required then least(greatest(r.makeup_rate, 0), 1)
        else least(greatest(
          (r.makeup_rate * least(r.total_weight, v_required)
            + cm.cohort_makeup * (v_required - least(r.total_weight, v_required))
          ) / v_required,
          0
        ), 1)
      end as makeup_rate,
      case
        when r.total_weight >= v_required then least(greatest(r.late_rate, 0), 1)
        else least(greatest(
          (r.late_rate * least(r.total_weight, v_required)
            + cm.cohort_late * (v_required - least(r.total_weight, v_required))
          ) / v_required,
          0
        ), 1)
      end as late_rate
    from raw_scores r
    cross join cohort_means cm
  ),
  scored as (
    select
      a.student_id,
      a.absence_rate,
      a.makeup_rate,
      a.late_rate,
      a.total_weight,
      (a.total_weight < v_required) as insufficient_evidence,
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
  ),
  ranked as (
    select
      s.*,
      rank() over (
        order by
          s.absence_band asc,
          s.score100 desc,
          s.makeup_rate asc,
          s.late_rate asc
      )::integer as rank,
      count(*) over ()::integer as cohort_size
    from scored s
  )
  select
    round(r.score100::numeric, 1) as score100,
    r.rank,
    r.cohort_size,
    round(((r.rank::numeric / nullif(r.cohort_size, 0)) * 100), 1)
      as top_percent,
    round(r.absence_rate::numeric, 4) as absence_rate,
    round(r.makeup_rate::numeric, 4) as makeup_rate,
    round(r.late_rate::numeric, 4) as late_rate,
    r.insufficient_evidence
  from ranked r
  where r.student_id = v_student;
end;
$$;

revoke all on function public.student_get_attendance_score_v1() from public;
grant execute on function public.student_get_attendance_score_v1() to authenticated;
