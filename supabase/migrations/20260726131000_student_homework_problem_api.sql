-- 20260726131000: 학생앱 문항 단위 과제 (마스터리 루프)
--
-- 마이그레이션 교재로 낸 과제는 homework_item_problems 에 문항 스냅샷이 남는다.
-- 학생앱이 그 문항들을 풀고 채점받을 수 있도록 조회 경로를 열고, "배정된 문항을
-- 전부 맞히면 통과" 규칙을 서버에서 판정한다.
--
-- 통과 판정 근거는 learning_attempts 다. student_textbook_answer_records 는
-- (student_id, crop_id) 유일키라 과제·회차와 무관한 최신 상태 캐시일 뿐이어서
-- 마스터리 판정에 쓸 수 없다.
--
-- 규칙 (docs/architecture/learning-records.md §9):
--   * 한 번 맞힌 문항은 통과 상태를 유지한다 (다음 회차에서 오답만 재출제).
--   * 자동채점(auto)과 학생 자가표시(self) 모두 통과로 인정한다.
--     self 는 신뢰도가 낮으므로 통계 뷰에서 따로 걸러낸다.
--   * 문항 정보가 없는 legacy 과제는 이 경로로 통과시키지 않는다.

-- ---------------------------------------------------------------------------
-- 1) 학생 본인 과제 문항 SELECT
-- ---------------------------------------------------------------------------
drop policy if exists homework_item_problems_student_app_select
  on public.homework_item_problems;
create policy homework_item_problems_student_app_select
  on public.homework_item_problems
for select to authenticated
using (
  exists (
    select 1
    from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.student_id = homework_item_problems.student_id
      and a.academy_id = homework_item_problems.academy_id
  )
);

-- ---------------------------------------------------------------------------
-- 2) 그룹 소유 검증 헬퍼
-- ---------------------------------------------------------------------------
create or replace function public._student_owned_group(p_group_id uuid)
returns table(academy_id uuid, student_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select g.academy_id, g.student_id
  from public.homework_groups g
  join public.student_app_identity() i
    on i.academy_id = g.academy_id
   and i.student_id = g.student_id
  where g.id = p_group_id
  limit 1;
$$;

revoke all on function public._student_owned_group(uuid) from public;
grant execute on function public._student_owned_group(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) 과제 그룹의 배정 문항 + 통과 상태
-- ---------------------------------------------------------------------------
create or replace function public.student_list_homework_problems_v1(
  p_group_id uuid
)
returns table(
  homework_item_id uuid,
  homework_item_problem_id uuid,
  item_title text,
  item_order integer,
  sort_order integer,
  crop_id uuid,
  pb_question_uid uuid,
  book_id uuid,
  grade_label text,
  problem_number text,
  raw_page integer,
  display_page integer,
  big_name text,
  mid_name text,
  type_group_label text,
  source_stage text,
  passed boolean,
  attempt_count integer,
  last_result text,
  last_attempted_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select o.academy_id, o.student_id into v_academy, v_student
  from public._student_owned_group(p_group_id) o;

  if v_student is null then
    raise exception 'student_list_homework_problems_v1: forbidden';
  end if;

  return query
  select
    p.homework_item_id,
    p.id                          as homework_item_problem_id,
    coalesce(hi.title, '')        as item_title,
    coalesce(gi.item_order_index, 0) as item_order,
    p.sort_order,
    p.crop_id,
    p.pb_question_uid,
    p.book_id,
    p.grade_label,
    p.problem_number,
    p.raw_page,
    p.display_page,
    p.big_name,
    p.mid_name,
    p.type_group_label,
    coalesce(p.source_stage, 'original') as source_stage,
    coalesce(a.has_correct, false)       as passed,
    coalesce(a.attempts, 0)::integer     as attempt_count,
    a.last_result,
    a.last_attempted_at
  from public.homework_group_items gi
  join public.homework_items hi
    on hi.id = gi.homework_item_id
   and hi.academy_id = gi.academy_id
  join public.homework_item_problems p
    on p.homework_item_id = hi.id
   and p.academy_id = hi.academy_id
  left join lateral (
    select
      bool_or(la.result = 'correct')            as has_correct,
      count(*)                                  as attempts,
      (array_agg(la.result order by la.attempted_at desc))[1]       as last_result,
      (array_agg(la.attempted_at order by la.attempted_at desc))[1] as last_attempted_at
    from public.learning_attempts la
    where la.homework_item_problem_id = p.id
  ) a on true
  where gi.group_id = p_group_id
    and gi.academy_id = v_academy
    and gi.student_id = v_student
  order by coalesce(gi.item_order_index, 0), p.sort_order;
end;
$$;

revoke all on function public.student_list_homework_problems_v1(uuid) from public;
grant execute on function public.student_list_homework_problems_v1(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4) 마스터리 진행 상태 요약
-- ---------------------------------------------------------------------------
-- 반환: { problem_based, total, passed, remaining, mastered,
--         items_total, items_without_problems }
create or replace function public._homework_group_mastery_state(
  p_academy_id uuid,
  p_student_id uuid,
  p_group_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_items_total integer := 0;
  v_items_without integer := 0;
  v_total integer := 0;
  v_passed integer := 0;
begin
  select
    count(*),
    count(*) filter (where pc.problem_count = 0)
  into v_items_total, v_items_without
  from public.homework_group_items gi
  join public.homework_items hi
    on hi.id = gi.homework_item_id
   and hi.academy_id = gi.academy_id
  cross join lateral (
    select count(*) as problem_count
    from public.homework_item_problems p
    where p.homework_item_id = hi.id
      and p.academy_id = hi.academy_id
  ) pc
  where gi.group_id = p_group_id
    and gi.academy_id = p_academy_id
    and gi.student_id = p_student_id;

  select
    count(*),
    count(*) filter (
      where exists (
        select 1
        from public.learning_attempts la
        where la.homework_item_problem_id = p.id
          and la.result = 'correct'
      )
    )
  into v_total, v_passed
  from public.homework_group_items gi
  join public.homework_item_problems p
    on p.homework_item_id = gi.homework_item_id
   and p.academy_id = gi.academy_id
  where gi.group_id = p_group_id
    and gi.academy_id = p_academy_id
    and gi.student_id = p_student_id;

  return jsonb_build_object(
    'problem_based', (v_items_total > 0 and v_items_without = 0 and v_total > 0),
    'items_total', v_items_total,
    'items_without_problems', v_items_without,
    'total', v_total,
    'passed', v_passed,
    'remaining', greatest(0, v_total - v_passed),
    'mastered', (v_total > 0 and v_passed >= v_total)
  );
end;
$$;

revoke all on function public._homework_group_mastery_state(uuid, uuid, uuid)
  from public;
grant execute on function public._homework_group_mastery_state(uuid, uuid, uuid)
  to authenticated;

create or replace function public.student_homework_group_mastery_v1(
  p_group_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select o.academy_id, o.student_id into v_academy, v_student
  from public._student_owned_group(p_group_id) o;

  if v_student is null then
    raise exception 'student_homework_group_mastery_v1: forbidden';
  end if;

  return public._homework_group_mastery_state(v_academy, v_student, p_group_id);
end;
$$;

revoke all on function public.student_homework_group_mastery_v1(uuid) from public;
grant execute on function public.student_homework_group_mastery_v1(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5) 전원 정답이면 통과 처리
-- ---------------------------------------------------------------------------
-- 학생앱 자체 채점으로 배정 문항을 모두 맞힌 경우에만 완료시킨다.
-- 그 외에는 아무것도 바꾸지 않고 사유를 돌려준다 (통과 경로를 검사/자체채점
-- 두 가지로 제한하기 위함).
create or replace function public.student_complete_homework_group_if_mastered(
  p_group_id uuid
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_state jsonb;
  v_item record;
  v_assignment uuid;
  v_completed integer := 0;
  v_progress integer;
begin
  select o.academy_id, o.student_id into v_academy, v_student
  from public._student_owned_group(p_group_id) o;

  if v_student is null then
    raise exception 'student_complete_homework_group_if_mastered: forbidden';
  end if;

  v_state := public._homework_group_mastery_state(v_academy, v_student, p_group_id);

  if not (v_state->>'problem_based')::boolean then
    return v_state || jsonb_build_object('ok', false, 'reason', 'not_problem_based');
  end if;

  if not (v_state->>'mastered')::boolean then
    return v_state || jsonb_build_object('ok', false, 'reason', 'incomplete');
  end if;

  v_progress := 100;

  for v_item in
    select gi.homework_item_id as item_id
    from public.homework_group_items gi
    join public.homework_items hi
      on hi.id = gi.homework_item_id
     and hi.academy_id = gi.academy_id
    where gi.group_id = p_group_id
      and gi.academy_id = v_academy
      and gi.student_id = v_student
      and coalesce(hi.status, 0) <> 1
  loop
    -- 활성 배정이 있으면 검사 이력으로도 남긴다 (진행률 100%).
    select ha.id into v_assignment
    from public.homework_assignments ha
    where ha.homework_item_id = v_item.item_id
      and ha.academy_id = v_academy
      and ha.status not in ('completed', 'canceled')
    order by ha.assigned_at desc
    limit 1;

    if v_assignment is not null then
      perform public.homework_assignment_check(
        v_assignment,
        v_academy,
        v_progress,
        null::text,
        '학생앱 자체 채점 전원 정답'::text,
        null::text
      );

      update public.homework_assignments
         set status = 'completed',
             updated_at = now(),
             version = coalesce(version, 1) + 1
       where id = v_assignment
         and academy_id = v_academy;
    end if;

    perform public.homework_complete(v_item.item_id, v_academy);
    v_completed := v_completed + 1;
  end loop;

  return v_state || jsonb_build_object(
    'ok', true,
    'reason', 'mastered',
    'completed_items', v_completed
  );
end;
$$;

revoke all on function public.student_complete_homework_group_if_mastered(uuid)
  from public;
grant execute on function public.student_complete_homework_group_if_mastered(uuid)
  to authenticated;

comment on function public.student_complete_homework_group_if_mastered(uuid) is
  '학생앱 자체 채점으로 배정 문항을 전부 맞힌 경우에만 그룹 과제를 완료시킨다. '
  '문항 정보가 없는 과제(legacy)는 통과시키지 않는다.';
