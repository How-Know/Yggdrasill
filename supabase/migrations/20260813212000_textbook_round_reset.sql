-- 다시 풀기 — 기록은 남기고 화면만 초기화한다.
--
-- 지금까지 "리셋"은 스태프용 unbind_student_textbook 하나뿐이었고, 그건 답
-- 기록·과제·학습 세션을 통째로 지운다. 교재를 다시 풀어 보고 싶을 뿐인데
-- 지난 풀이가 사라지면 안 된다.
--
-- 여기서 하는 일은 두 가지다. 열린 회차를 닫고, 답 캐시를 비운다.
-- learning_attempts / student_problem_rounds 의 과거 기록은 그대로 남는다.
-- 다음에 다시 풀면 새 회차가 열린다.

-- ---------------------------------------------------------------------------
-- 공통 처리
-- ---------------------------------------------------------------------------
create or replace function public._reset_textbook_rounds(
  p_academy_id uuid,
  p_student_id uuid,
  p_crop_ids uuid[]
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
begin
  if p_student_id is null
     or p_crop_ids is null
     or array_length(p_crop_ids, 1) is null then
    return 0;
  end if;

  -- 1) 열린 회차를 닫는다. 다음 시도부터 새 회차가 열린다.
  update public.student_problem_rounds r
  set closed_at = now(),
      close_reason = 'reset',
      updated_at = now()
  where r.student_id = p_student_id
    and r.academy_id = p_academy_id
    and r.crop_id = any(p_crop_ids)
    and r.closed_at is null;

  -- 2) 답 캐시를 비운다. 행은 남겨 둔다. first_attempt_correct 는 "이 문항을
  --    처음 만났을 때 맞혔는가"라 다시 풀기로 바뀌면 안 되므로 손대지 않는다.
  update public.student_textbook_answer_records a
  set last_answer = null,
      is_correct = false,
      attempt_count = 0,
      first_correct_at = null,
      part_results = null,
      graded_by = 'auto',
      flags = '{}',
      updated_at = now()
  where a.student_id = p_student_id
    and a.academy_id = p_academy_id
    and a.crop_id = any(p_crop_ids);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 학생: 교재(학년) 단위로 다시 풀기
-- ---------------------------------------------------------------------------
create or replace function public.student_reset_textbook_v1(
  p_book_id uuid,
  p_grade_label text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_crops uuid[];
  v_reset integer := 0;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    return jsonb_build_object('ok', false, 'error', 'no_student_account');
  end if;
  if p_book_id is null then
    return jsonb_build_object('ok', false, 'error', 'book_id_required');
  end if;

  -- 선생님이 검사 중인 교재는 손대지 않는다. 제출(3)·확인(4) 단계에서
  -- 답이 사라지면 검사하던 화면과 어긋난다.
  if exists (
    select 1
    from public.homework_items hi
    join public.homework_item_problems p
      on p.homework_item_id = hi.id
     and p.academy_id = hi.academy_id
    where p.student_id = v_student
      and p.academy_id = v_academy
      and p.book_id = p_book_id
      and p.grade_label is not distinct from p_grade_label
      and coalesce(hi.phase, 1) in (3, 4)
  ) then
    return jsonb_build_object('ok', false, 'error', 'under_review');
  end if;

  select array_agg(c.id) into v_crops
  from public.textbook_problem_crops c
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label;

  v_reset := public._reset_textbook_rounds(v_academy, v_student, v_crops);

  return jsonb_build_object(
    'ok', true,
    'reset_problems', v_reset,
    'scope', 'book'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 스태프: 문항 단위까지 다시 풀기
-- ---------------------------------------------------------------------------
create or replace function public.staff_reset_student_problems_v1(
  p_student_id uuid,
  p_crop_ids uuid[] default null,
  p_book_id uuid default null,
  p_grade_label text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_crops uuid[] := p_crop_ids;
  v_reset integer := 0;
begin
  select s.academy_id into v_academy
  from public.students s
  where s.id = p_student_id;

  if v_academy is null then
    return jsonb_build_object('ok', false, 'error', 'student_not_found');
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_reset_student_problems_v1: forbidden';
  end if;

  -- 문항을 안 주면 교재(학년) 전체로 본다.
  if v_crops is null or array_length(v_crops, 1) is null then
    if p_book_id is null then
      return jsonb_build_object('ok', false, 'error', 'crop_ids_or_book_required');
    end if;
    select array_agg(c.id) into v_crops
    from public.textbook_problem_crops c
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label;
  end if;

  v_reset := public._reset_textbook_rounds(v_academy, p_student_id, v_crops);

  return jsonb_build_object(
    'ok', true,
    'reset_problems', v_reset,
    'scope', case when p_crop_ids is not null then 'problems' else 'book' end
  );
end;
$$;

revoke all on function public._reset_textbook_rounds(uuid, uuid, uuid[]) from public;

revoke all on function public.student_reset_textbook_v1(uuid, text) from public;
grant execute on function public.student_reset_textbook_v1(uuid, text)
  to authenticated;

revoke all on function public.staff_reset_student_problems_v1(
  uuid, uuid[], uuid, text
) from public;
grant execute on function public.staff_reset_student_problems_v1(
  uuid, uuid[], uuid, text
) to authenticated;
