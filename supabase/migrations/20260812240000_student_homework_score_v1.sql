-- 20260812240000: 학생앱용 과제 점수 RPC
--
-- 학습앱 스탯의 과제 점수(_homework_score_all_v2)와 동일 산식.
-- 출석 점수(student_get_attendance_score_v1)와 같은 형태로
-- score100 + 학원 내 순위/상위% 를 돌려준다.

create or replace function public.student_get_homework_score_v1()
returns table(
  score100 numeric,
  rank integer,
  cohort_size integer,
  top_percent numeric,
  evaluated_count integer,
  completed_count integer,
  pending_count integer,
  insufficient_evidence boolean,
  has_score boolean
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
  with ranked as (
    select
      h.student_id,
      h.score100,
      h.evaluated_count,
      h.completed_count,
      h.pending_count,
      h.insufficient_evidence,
      (h.evaluated_count > 0) as has_score,
      count(*) over ()::integer as cohort_size,
      rank() over (
        order by
          case when h.evaluated_count > 0 then h.score100 else -1 end desc,
          h.student_id
      )::integer as rnk
    from public._homework_score_all_v2(v_academy) h
  )
  select
    case when r.has_score then round(r.score100::numeric, 1) else null end
      as score100,
    case when r.has_score then r.rnk else 0 end as rank,
    r.cohort_size,
    case
      when r.has_score and r.cohort_size > 0
      then round(((r.rnk::numeric / r.cohort_size) * 100), 1)
      else 0::numeric
    end as top_percent,
    r.evaluated_count,
    r.completed_count,
    r.pending_count,
    r.insufficient_evidence,
    r.has_score
  from ranked r
  where r.student_id = v_student;
end;
$$;

revoke all on function public.student_get_homework_score_v1() from public;
grant execute on function public.student_get_homework_score_v1() to authenticated;

comment on function public.student_get_homework_score_v1() is
  '학생앱용 과제 점수. 학습앱 _homework_score_all_v2 와 동일 산식 + 학원 순위.';
