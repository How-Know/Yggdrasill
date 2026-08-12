-- 20260813010000: 학생앱용 포인트 요약 RPC
--
-- 학습앱 포인트 카드와 동일 기준:
--   * 표시 숫자: lifetime_earned (누적 획득 — 써도 줄지 않음)
--   * 순위: lifetime_earned 기준, 원장 없는 학생도 0으로 코호트에 포함

create or replace function public.student_get_point_summary_v1()
returns table(
  lifetime_earned integer,
  balance integer,
  lifetime_spent integer,
  entry_count integer,
  rank integer,
  cohort_size integer,
  top_percent numeric,
  last_event_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_season uuid := '00000000-0000-0000-0000-000000000000'::uuid;
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
  earned as (
    select
      c.student_id,
      coalesce(b.lifetime_earned, 0)::integer as lifetime_earned,
      coalesce(b.balance, 0)::integer as balance,
      coalesce(b.lifetime_spent, 0)::integer as lifetime_spent,
      coalesce(b.entry_count, 0)::integer as entry_count,
      b.last_event_at
    from cohort c
    left join public.student_point_balances b
      on b.academy_id = v_academy
     and b.student_id = c.student_id
     and b.season_id = v_season
  ),
  ranked as (
    select
      e.*,
      count(*) over ()::integer as cohort_size,
      rank() over (
        order by e.lifetime_earned desc, e.student_id
      )::integer as rnk
    from earned e
  )
  select
    r.lifetime_earned,
    r.balance,
    r.lifetime_spent,
    r.entry_count,
    r.rnk as rank,
    r.cohort_size,
    round(((r.rnk::numeric / nullif(r.cohort_size, 0)) * 100), 1) as top_percent,
    r.last_event_at
  from ranked r
  where r.student_id = v_student;
end;
$$;

revoke all on function public.student_get_point_summary_v1() from public;
grant execute on function public.student_get_point_summary_v1() to authenticated;

comment on function public.student_get_point_summary_v1() is
  '학생앱용 포인트 요약. 누적 획득(lifetime_earned)과 그 기준 학원 순위를 반환.';
