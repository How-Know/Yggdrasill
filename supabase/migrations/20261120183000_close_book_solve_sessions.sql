-- 풀이 종료는 화면이 기억한 세션 한 줄만 닫으면, 같은 교재에 남은 중단 세션이
-- 카드의 중단 칩으로 다시 보인다. 그 교재의 바로풀기 세션을 한꺼번에 맞춘다.

create or replace function public.student_set_textbook_solve_sessions_v1(
  p_book_id uuid,
  p_grade_label text,
  p_action text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_student uuid;
  v_action text := lower(btrim(coalesce(p_action, '')));
  v_grade text := coalesce(p_grade_label, '');
  v_count integer := 0;
begin
  select i.student_id into v_student
  from public.student_app_identity() i;
  if v_student is null or p_book_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  if v_action not in ('finish', 'pause') then
    return jsonb_build_object('ok', false, 'error', 'invalid_action');
  end if;

  if v_action = 'finish' then
    update public.learning_sessions s
    set status = 'completed',
        ended_at = coalesce(s.ended_at, now()),
        paused_at = null,
        updated_at = now()
    where s.student_id = v_student
      and s.book_id = p_book_id
      and s.entry_mode = 'solve'
      and s.status in ('open', 'paused');
    get diagnostics v_count = row_count;
  else
    update public.learning_sessions s
    set elapsed_sec = coalesce(s.elapsed_sec, 0) + greatest(
          0,
          floor(
            extract(epoch from (now() - coalesce(s.last_resumed_at, s.started_at)))
          )::integer
        ),
        status = 'paused',
        paused_at = now(),
        last_beat_at = now(),
        updated_at = now()
    where s.student_id = v_student
      and s.book_id = p_book_id
      and coalesce(s.grade_label, '') = v_grade
      and s.entry_mode = 'solve'
      and s.status = 'open';
    get diagnostics v_count = row_count;
  end if;

  return jsonb_build_object('ok', true, 'action', v_action, 'count', v_count);
end;
$$;

revoke all on function public.student_set_textbook_solve_sessions_v1(uuid, text, text)
  from public;
grant execute on function public.student_set_textbook_solve_sessions_v1(uuid, text, text)
  to authenticated;
