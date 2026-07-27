-- 학생-교재 바인딩 해제.
--
-- 이 학생의 해당 교재(book_id + grade_label) 관련 데이터만 삭제한다.
-- 원본 교재(textbook_metadata, textbook_problem_crops, resource_files,
-- student_grading_ai_cache 등 학원 공용 자산)는 절대 건드리지 않는다.

create or replace function public.unbind_student_textbook(
  p_student_id uuid,
  p_flow_id uuid,
  p_book_id uuid,
  p_grade_label text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_grade text := btrim(coalesce(p_grade_label, ''));
  v_links int := 0;
  v_answers int := 0;
  v_reports int := 0;
  v_handwriting int := 0;
  v_equiv int := 0;
  v_homework int := 0;
  v_sessions int := 0;
  v_prefs int := 0;
begin
  if p_student_id is null or p_flow_id is null or p_book_id is null or v_grade = '' then
    raise exception 'unbind_student_textbook: invalid args';
  end if;

  select s.academy_id into v_academy
  from public.students s
  where s.id = p_student_id;

  if v_academy is null then
    raise exception 'unbind_student_textbook: student not found';
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = v_academy
  ) then
    raise exception 'unbind_student_textbook: not a staff member';
  end if;

  -- 플로우가 해당 학생 소유인지 확인 (타 학생/공용 데이터 오삭제 방지)
  if not exists (
    select 1 from public.student_flows f
    where f.id = p_flow_id
      and f.student_id = p_student_id
      and f.academy_id = v_academy
  ) then
    raise exception 'unbind_student_textbook: flow mismatch';
  end if;

  perform set_config('statement_timeout', '60s', true);

  -- 1) 필기 샘플 (reports FK)
  delete from public.student_handwriting_samples h
  where h.academy_id = v_academy
    and h.student_id = p_student_id
    and h.book_id = p_book_id
    and h.grade_label = v_grade;
  get diagnostics v_handwriting = row_count;

  -- 2) 문항 신고
  delete from public.student_textbook_problem_reports r
  where r.academy_id = v_academy
    and r.student_id = p_student_id
    and r.book_id = p_book_id
    and r.grade_label = v_grade;
  get diagnostics v_reports = row_count;

  -- 3) 풀이/채점 기록
  delete from public.student_textbook_answer_records a
  where a.academy_id = v_academy
    and a.student_id = p_student_id
    and a.book_id = p_book_id
    and a.grade_label = v_grade;
  get diagnostics v_answers = row_count;

  -- 4) 동치 채점 로그 (학생 스코프)
  delete from public.student_grading_equiv_logs g
  where g.academy_id = v_academy
    and g.student_id = p_student_id
    and g.book_id = p_book_id
    and g.grade_label = v_grade;
  get diagnostics v_equiv = row_count;

  -- 5) 해당 교재 과제 (하위 pages/problems/assignments 등은 cascade)
  delete from public.homework_items i
  where i.academy_id = v_academy
    and i.student_id = p_student_id
    and i.book_id = p_book_id
    and i.grade_label = v_grade;
  get diagnostics v_homework = row_count;

  -- 빈 그룹 정리
  delete from public.homework_groups g
  where g.academy_id = v_academy
    and g.student_id = p_student_id
    and not exists (
      select 1
      from public.homework_group_items gi
      where gi.group_id = g.id
    );

  -- 6) 학습 세션 (exposures/attempts/range_timings cascade)
  delete from public.learning_sessions s
  where s.academy_id = v_academy
    and s.student_id = p_student_id
    and s.book_id = p_book_id
    and coalesce(s.grade_label, '') = v_grade;
  get diagnostics v_sessions = row_count;

  -- 세션 없이 남은 구간 시간 기록
  delete from public.learning_range_timings t
  where t.academy_id = v_academy
    and t.student_id = p_student_id
    and t.book_id = p_book_id
    and coalesce(t.grade_label, '') = v_grade;

  -- 7) 활성 교재 override (이 학생·교재 전부)
  delete from public.student_textbook_link_preferences p
  where p.academy_id = v_academy
    and p.student_id = p_student_id
    and p.book_id = p_book_id
    and p.grade_label = v_grade;
  get diagnostics v_prefs = row_count;

  -- 8) 플로우 바인딩 행만 제거 (원본 교재 테이블 아님)
  delete from public.flow_textbook_links l
  where l.academy_id = v_academy
    and l.flow_id = p_flow_id
    and l.book_id = p_book_id
    and l.grade_label = v_grade;
  get diagnostics v_links = row_count;

  return jsonb_build_object(
    'ok', true,
    'links', v_links,
    'answers', v_answers,
    'reports', v_reports,
    'handwriting', v_handwriting,
    'equiv_logs', v_equiv,
    'homework_items', v_homework,
    'learning_sessions', v_sessions,
    'preferences', v_prefs
  );
end;
$$;

revoke all on function public.unbind_student_textbook(uuid, uuid, uuid, text) from public;
grant execute on function public.unbind_student_textbook(uuid, uuid, uuid, text) to authenticated;

comment on function public.unbind_student_textbook(uuid, uuid, uuid, text) is
  '학생-플로우 교재 바인딩 해제. 학생 스코프 데이터만 삭제하고 원본 교재/메타데이터는 유지.';
