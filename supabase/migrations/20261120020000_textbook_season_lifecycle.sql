-- 교재 시즌 생명주기 확장:
--   1) 처음 등록한 교재는 시즌 행을 미리 만들지 않아 `시작 전(not_started)` 상태로 둔다.
--      학생이 `시즌 1 시작`을 누르거나, 바로 문제를 풀거나, 선생님이 과제를 출제하면
--      시즌 1이 열리며 활성화(`active`)된다.
--   2) 진행 중인 시즌은 `보류(paused)`와 `재개(active)`를 오갈 수 있다(답·완료 기록 유지).
--   3) `시즌 종료(end)`는 곧바로 다음 시즌을 열거나 답 캐시를 지우지 않고,
--      스냅샷을 남긴 채 현재 시즌만 마감(`closed`)한다.
--      한 번이라도 모든 문항을 다 푼 문제집은 `완료됨`, 그 외는 `종료됨`으로 분류된다.
--   4) 마감된 교재에서 `시즌 N+1 시작`을 누를 때 이전 답 표시를 비우고 다음 시즌을 연다.
--      학생이 이미 시즌을 마감한 뒤 선생님이 `시즌 업`을 눌러도 시즌이 두 칸 뛰지 않는다.

-- ---------------------------------------------------------------------------
-- 1) 시즌 테이블 컬럼 및 제약 확장
-- ---------------------------------------------------------------------------
alter table public.student_textbook_seasons
  add column if not exists paused_at timestamptz;

alter table public.student_textbook_seasons
  drop constraint if exists student_textbook_seasons_close_chk;

alter table public.student_textbook_seasons
  add constraint student_textbook_seasons_close_chk check (
    close_reason is null
    or close_reason in ('ended', 'completed', 'reset', 'backfill')
  );

-- ---------------------------------------------------------------------------
-- 2) 내부 헬퍼: 시즌 기준 문항 전체 수·완료 수 계산
-- ---------------------------------------------------------------------------
create or replace function public._student_book_season_completion_counts(
  p_academy_id uuid,
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_season_id uuid,
  p_season_no integer,
  p_season_opened_at timestamptz
) returns table(
  total_problems integer,
  completed_problems integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_grade text := coalesce(p_grade_label, '');
  v_season_no integer := coalesce(p_season_no, 1);
begin
  return query
  with gradable as (
    select
      c.id as crop_id,
      c.book_id,
      c.grade_label,
      c.raw_page,
      c.display_page
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    where c.academy_id = p_academy_id
      and c.book_id = p_book_id
      and c.grade_label = v_grade
      and not c.is_set_header
      and (
        (
          a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null
        )
        or a.answer_kind = 'image'
      )
      and not public._student_crop_on_hold(p_student_id, c.id)
  ),
  season_passed as (
    select distinct g.crop_id
    from gradable g
    join public.student_problem_rounds pr
      on pr.student_id = p_student_id
     and pr.crop_id = g.crop_id
     and pr.passed
     and (
       (p_season_id is not null and pr.season_id = p_season_id)
       or (p_season_id is null and pr.season_id is null)
     )
  ),
  teacher_done as (
    select distinct g.crop_id
    from gradable g
    join public.homework_item_units u
      on u.academy_id = p_academy_id
     and u.student_id = p_student_id
     and u.book_id = g.book_id
     and u.grade_label = g.grade_label
    join public.homework_items h
      on h.id = u.homework_item_id
     and h.student_id = p_student_id
     and h.academy_id = p_academy_id
    where (
      h.completed_at is not null
      or coalesce(h.status, 0) = 1
      or h.confirmed_at is not null
      or coalesce(h.phase, 0) = 4
    )
    and (
      v_season_no <= 1
      or p_season_opened_at is null
      or coalesce(h.completed_at, h.confirmed_at, h.created_at) >= p_season_opened_at
    )
    and (
      g.raw_page between least(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
                     and greatest(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
      or g.display_page between least(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
                            and greatest(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
    )
    union
    select distinct g.crop_id
    from gradable g
    join public.homework_item_problems hip
      on hip.academy_id = p_academy_id
     and hip.student_id = p_student_id
     and hip.crop_id = g.crop_id
     and hip.excluded_at is null
    join public.homework_items h
      on h.id = hip.homework_item_id
     and h.student_id = p_student_id
     and h.academy_id = p_academy_id
    where (
      h.completed_at is not null
      or coalesce(h.status, 0) = 1
      or (coalesce(h.phase, 0) = 4 and coalesce(h.pending_complete, false))
    )
    and coalesce(h.time_limit_minutes, 0) <= 0
    and (
      v_season_no <= 1
      or p_season_opened_at is null
      or coalesce(h.completed_at, h.confirmed_at, h.created_at) >= p_season_opened_at
    )
  )
  select
    count(*)::integer as total_problems,
    count(*) filter (
      where coalesce(r.is_correct, false)
         or sp.crop_id is not null
         or td.crop_id is not null
    )::integer as completed_problems
  from gradable g
  left join public.student_textbook_answer_records r
    on r.crop_id = g.crop_id
   and r.student_id = p_student_id
  left join season_passed sp on sp.crop_id = g.crop_id
  left join teacher_done td on td.crop_id = g.crop_id;
end;
$$;

revoke all on function public._student_book_season_completion_counts(
  uuid, uuid, uuid, text, uuid, integer, timestamptz
) from public;

-- ---------------------------------------------------------------------------
-- 3) 내부 헬퍼: 활성 시즌 보장 (보류 중이면 재개, 마감 후 새 시즌이면 이전 답 정리)
-- ---------------------------------------------------------------------------
create or replace function public._student_ensure_active_textbook_season(
  p_academy_id uuid,
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_preserve_crop_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_grade text := coalesce(p_grade_label, '');
  v_open public.student_textbook_seasons%rowtype;
  v_id uuid;
  v_max_season integer := 0;
  v_crops uuid[];
begin
  if p_student_id is null or p_book_id is null then
    return null;
  end if;

  select * into v_open
  from public.student_textbook_seasons
  where student_id = p_student_id
    and book_id = p_book_id
    and grade_label = v_grade
    and closed_at is null
  limit 1
  for update;

  if v_open.id is not null then
    if v_open.paused_at is not null then
      update public.student_textbook_seasons
      set paused_at = null,
          updated_at = now()
      where id = v_open.id;
    end if;
    return v_open.id;
  end if;

  select coalesce(max(season_no), 0) into v_max_season
  from public.student_textbook_seasons
  where student_id = p_student_id
    and book_id = p_book_id
    and grade_label = v_grade;

  -- 이전 시즌을 마감(`시즌 종료`)해 둔 상태에서 다음 시즌이 열리는 순간
  -- 이전 시즌의 답 표시를 비운다 (방금 채점한 문항 `p_preserve_crop_id`는 보존).
  if v_max_season >= 1 then
    select array_agg(c.id) into v_crops
    from public.textbook_problem_crops c
    where c.academy_id = p_academy_id
      and c.book_id = p_book_id
      and c.grade_label = v_grade
      and (p_preserve_crop_id is null or c.id <> p_preserve_crop_id);

    if v_crops is not null and array_length(v_crops, 1) is not null then
      perform public._reset_textbook_rounds(p_academy_id, p_student_id, v_crops);
    end if;
  end if;

  insert into public.student_textbook_seasons (
    academy_id, student_id, book_id, grade_label, season_no
  ) values (
    p_academy_id, p_student_id, p_book_id, v_grade, v_max_season + 1
  )
  on conflict (student_id, book_id, grade_label) where closed_at is null
  do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id
    from public.student_textbook_seasons
    where student_id = p_student_id
      and book_id = p_book_id
      and grade_label = v_grade
      and closed_at is null
    limit 1;
  end if;

  return v_id;
end;
$$;

revoke all on function public._student_ensure_active_textbook_season(
  uuid, uuid, uuid, text, uuid
) from public;

create or replace function public._student_current_textbook_season(
  p_academy_id uuid,
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  return public._student_ensure_active_textbook_season(
    p_academy_id, p_student_id, p_book_id, p_grade_label, null
  );
end;
$$;

revoke all on function public._student_current_textbook_season(
  uuid, uuid, uuid, text
) from public;

-- ---------------------------------------------------------------------------
-- 4) 회차 열기: 마감된 교재에서 바로 채점해도 방금 입력한 답을 지우지 않고 새 시즌 연결
-- ---------------------------------------------------------------------------
create or replace function public._student_open_problem_round(
  p_academy_id uuid,
  p_student_id uuid,
  p_crop_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_origin text,
  p_homework_group_id uuid default null,
  p_homework_item_problem_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_open public.student_problem_rounds%rowtype;
  v_next integer;
  v_id uuid;
  v_book uuid := p_book_id;
  v_grade text := p_grade_label;
  v_season uuid;
begin
  if p_crop_id is null or p_student_id is null then
    return null;
  end if;

  if v_book is null then
    select c.book_id, c.grade_label into v_book, v_grade
    from public.textbook_problem_crops c
    where c.id = p_crop_id;
  end if;

  select * into v_open
  from public.student_problem_rounds
  where student_id = p_student_id
    and crop_id = p_crop_id
    and closed_at is null
  limit 1
  for update;

  if v_open.id is not null then
    if p_homework_item_problem_id is not null
       and v_open.homework_item_problem_id is not null
       and v_open.homework_item_problem_id <> p_homework_item_problem_id then
      update public.student_problem_rounds
      set closed_at = now(),
          close_reason = 'reassigned',
          updated_at = now()
      where id = v_open.id;
    else
      if p_homework_item_problem_id is not null
         and v_open.homework_item_problem_id is null then
        update public.student_problem_rounds
        set homework_item_problem_id = p_homework_item_problem_id,
            homework_group_id =
              coalesce(p_homework_group_id, homework_group_id),
            origin = case when origin = 'free_practice' then 'homework'
                          else origin end,
            updated_at = now()
        where id = v_open.id;
      end if;

      v_season := public._student_ensure_active_textbook_season(
        p_academy_id, p_student_id, v_book, v_grade, p_crop_id
      );
      if v_open.season_id is null and v_season is not null then
        update public.student_problem_rounds
        set season_id = v_season, updated_at = now()
        where id = v_open.id;
      end if;

      return v_open.id;
    end if;
  end if;

  v_season := public._student_ensure_active_textbook_season(
    p_academy_id, p_student_id, v_book, v_grade, p_crop_id
  );

  select coalesce(max(round_no), 0) + 1 into v_next
  from public.student_problem_rounds
  where student_id = p_student_id
    and crop_id = p_crop_id;

  insert into public.student_problem_rounds (
    academy_id, student_id, crop_id, book_id, grade_label,
    round_no, origin, homework_group_id, homework_item_problem_id,
    season_id
  ) values (
    p_academy_id, p_student_id, p_crop_id, v_book, v_grade,
    v_next,
    case when p_origin in ('homework', 'free_practice', 'reset')
      then p_origin else 'unknown' end,
    p_homework_group_id, p_homework_item_problem_id,
    v_season
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public._student_open_problem_round(
  uuid, uuid, uuid, uuid, text, text, uuid, uuid
) from public;

-- ---------------------------------------------------------------------------
-- 5) 내부 헬퍼: 현재 열린 시즌만 마감(스냅샷 기록, 답 캐시는 건드리지 않음)
-- ---------------------------------------------------------------------------
create or replace function public._student_close_open_textbook_season(
  p_academy_id uuid,
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_close_reason text default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_grade text := coalesce(p_grade_label, '');
  v_open public.student_textbook_seasons%rowtype;
  v_total integer := 0;
  v_completed integer := 0;
  v_touched integer := 0;
  v_passed integer := 0;
  v_all_completed boolean := false;
  v_reason text;
  v_problems jsonb;
begin
  if p_student_id is null or p_book_id is null then
    return null;
  end if;

  select * into v_open
  from public.student_textbook_seasons
  where student_id = p_student_id
    and book_id = p_book_id
    and grade_label = v_grade
    and closed_at is null
  limit 1
  for update;

  if v_open.id is null then
    return null;
  end if;

  select cc.total_problems, cc.completed_problems
    into v_total, v_completed
  from public._student_book_season_completion_counts(
    p_academy_id, p_student_id, p_book_id, v_grade,
    v_open.id, v_open.season_no, v_open.opened_at
  ) cc;

  v_total := coalesce(v_total, 0);
  v_completed := coalesce(v_completed, 0);
  v_all_completed := (v_total > 0 and v_completed >= v_total);

  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'crop_id', r.crop_id,
          'round_no', r.round_no,
          'passed', r.passed,
          'attempt_count', r.attempt_count
        )
        order by r.round_no
      ),
      '[]'::jsonb
    ),
    count(*),
    count(*) filter (where r.passed)
  into v_problems, v_touched, v_passed
  from public.student_problem_rounds r
  where r.season_id = v_open.id;

  -- 열린 문항 회차만 마감하고 답 캐시(student_textbook_answer_records)는 남겨 둔다.
  update public.student_problem_rounds pr
  set closed_at = now(),
      close_reason = 'reset',
      updated_at = now()
  where pr.student_id = p_student_id
    and pr.book_id = p_book_id
    and pr.grade_label is not distinct from v_grade
    and pr.closed_at is null;

  v_reason := case
    when v_all_completed then 'completed'
    when p_close_reason in ('ended', 'completed', 'reset', 'backfill') then p_close_reason
    else 'ended'
  end;

  update public.student_textbook_seasons
  set closed_at = now(),
      paused_at = null,
      close_reason = v_reason,
      snapshot = jsonb_build_object(
        'closed_at', now(),
        'problems', v_problems,
        'totals', jsonb_build_object(
          'book_problems', v_total,
          'completed', v_completed,
          'all_completed', v_all_completed,
          'rounds', v_touched,
          'passed', v_passed,
          'untouched', greatest(0, v_total - v_touched)
        )
      ),
      updated_at = now()
  where id = v_open.id;

  return v_open.season_no;
end;
$$;

revoke all on function public._student_close_open_textbook_season(
  uuid, uuid, uuid, text, text
) from public;

-- ---------------------------------------------------------------------------
-- 6) 시즌 전환(스태프 `시즌 업`·레거시 전체 리셋): 이미 닫힌 책을 두 번 넘기지 않는다
-- ---------------------------------------------------------------------------
create or replace function public._student_roll_textbook_season(
  p_academy_id uuid,
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_grade text := coalesce(p_grade_label, '');
  v_new_id uuid;
  v_new_no integer;
begin
  if p_student_id is null or p_book_id is null then
    return null;
  end if;

  -- 열린 시즌이 있을 때만 닫는다. 학생이 이미 `시즌 종료`로 닫아 둔 상태라면
  -- 다시 닫지 않고 곧바로 다음 시즌 하나만 연다.
  perform public._student_close_open_textbook_season(
    p_academy_id, p_student_id, p_book_id, v_grade, 'reset'
  );

  v_new_id := public._student_ensure_active_textbook_season(
    p_academy_id, p_student_id, p_book_id, v_grade, null
  );

  select s.season_no into v_new_no
  from public.student_textbook_seasons s
  where s.id = v_new_id;

  return coalesce(v_new_no, 1);
end;
$$;

revoke all on function public._student_roll_textbook_season(
  uuid, uuid, uuid, text
) from public;

-- 스태프 시즌 업: 답 캐시를 지우기 전에 열린 시즌 스냅샷을 먼저 찍어 완주 기록을 보존한다.
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
  v_book_scope boolean := p_crop_ids is null
    or array_length(p_crop_ids, 1) is null;
  v_season integer;
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

  if v_book_scope then
    if p_book_id is null then
      return jsonb_build_object('ok', false, 'error', 'crop_ids_or_book_required');
    end if;

    if exists (
      select 1
      from public.homework_items hi
      join public.homework_item_problems p
        on p.homework_item_id = hi.id
       and p.academy_id = hi.academy_id
      where p.student_id = p_student_id
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
      and c.grade_label = coalesce(p_grade_label, '');

    -- 답을 비우기 전에 열린 시즌이 있으면 먼저 닫아 완주 여부를 스냅샷에 남긴다.
    perform public._student_close_open_textbook_season(
      v_academy, p_student_id, p_book_id, p_grade_label, 'reset'
    );
  end if;

  v_reset := public._reset_textbook_rounds(v_academy, p_student_id, v_crops);

  if v_book_scope then
    v_season := public._student_roll_textbook_season(
      v_academy, p_student_id, p_book_id, p_grade_label
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'reset_problems', v_reset,
    'season_no', v_season,
    'scope', case when p_crop_ids is not null then 'problems' else 'book' end
  );
end;
$$;

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
  v_grade text := coalesce(p_grade_label, '');
  v_crops uuid[];
  v_reset integer := 0;
  v_season integer;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    return jsonb_build_object('ok', false, 'error', 'no_student_account');
  end if;
  if p_book_id is null then
    return jsonb_build_object('ok', false, 'error', 'book_id_required');
  end if;

  if exists (
    select 1
    from public.homework_items hi
    join public.homework_item_problems p
      on p.homework_item_id = hi.id
     and p.academy_id = hi.academy_id
    where p.student_id = v_student
      and p.academy_id = v_academy
      and p.book_id = p_book_id
      and p.grade_label is not distinct from v_grade
      and coalesce(hi.phase, 1) in (3, 4)
  ) then
    return jsonb_build_object('ok', false, 'error', 'under_review');
  end if;

  perform public._student_close_open_textbook_season(
    v_academy, v_student, p_book_id, v_grade, 'reset'
  );

  select array_agg(c.id) into v_crops
  from public.textbook_problem_crops c
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = v_grade;

  v_reset := public._reset_textbook_rounds(v_academy, v_student, v_crops);
  v_season := public._student_roll_textbook_season(
    v_academy, v_student, p_book_id, v_grade
  );

  return jsonb_build_object(
    'ok', true,
    'reset_problems', v_reset,
    'season_no', v_season,
    'scope', 'book'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7) 학생앱 시즌 상태 변경 RPC: start | pause | resume | end
-- ---------------------------------------------------------------------------
create or replace function public.student_set_textbook_season_state_v1(
  p_book_id uuid,
  p_grade_label text,
  p_action text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_grade text := coalesce(p_grade_label, '');
  v_action text := lower(trim(coalesce(p_action, '')));
  v_open public.student_textbook_seasons%rowtype;
  v_season_id uuid;
  v_season_no integer;
  v_ever_completed boolean := false;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    return jsonb_build_object('ok', false, 'error', 'no_student_account');
  end if;
  if p_book_id is null then
    return jsonb_build_object('ok', false, 'error', 'book_id_required');
  end if;
  if v_action not in ('start', 'pause', 'resume', 'end') then
    return jsonb_build_object('ok', false, 'error', 'invalid_action');
  end if;

  if v_action in ('start', 'end') then
    if exists (
      select 1
      from public.homework_items hi
      join public.homework_item_problems p
        on p.homework_item_id = hi.id
       and p.academy_id = hi.academy_id
      where p.student_id = v_student
        and p.academy_id = v_academy
        and p.book_id = p_book_id
        and p.grade_label is not distinct from v_grade
        and coalesce(hi.phase, 1) in (3, 4)
    ) then
      return jsonb_build_object('ok', false, 'error', 'under_review');
    end if;
  end if;

  if v_action in ('start', 'resume') then
    v_season_id := public._student_ensure_active_textbook_season(
      v_academy, v_student, p_book_id, v_grade, null
    );
    select s.season_no into v_season_no
    from public.student_textbook_seasons s
    where s.id = v_season_id;

    return jsonb_build_object(
      'ok', true,
      'season_state', 'active',
      'season_no', coalesce(v_season_no, 1)
    );
  end if;

  if v_action = 'pause' then
    select * into v_open
    from public.student_textbook_seasons s
    where s.student_id = v_student
      and s.book_id = p_book_id
      and s.grade_label = v_grade
      and s.closed_at is null
    limit 1
    for update;

    if v_open.id is null then
      v_season_id := public._student_ensure_active_textbook_season(
        v_academy, v_student, p_book_id, v_grade, null
      );
      update public.student_textbook_seasons
      set paused_at = now(),
          updated_at = now()
      where id = v_season_id
      returning season_no into v_season_no;
    else
      update public.student_textbook_seasons
      set paused_at = coalesce(paused_at, now()),
          updated_at = now()
      where id = v_open.id
      returning season_no into v_season_no;
    end if;

    return jsonb_build_object(
      'ok', true,
      'season_state', 'paused',
      'season_no', coalesce(v_season_no, 1)
    );
  end if;

  -- v_action = 'end'
  select * into v_open
  from public.student_textbook_seasons s
  where s.student_id = v_student
    and s.book_id = p_book_id
    and s.grade_label = v_grade
    and s.closed_at is null
  limit 1;

  if v_open.id is null then
    -- 시즌 행 생성 전 풀이만 있던 교재도 시즌 1을 먼저 연 뒤 마감해 기록을 남긴다.
    if exists (
      select 1 from public.student_textbook_seasons s
      where s.student_id = v_student
        and s.book_id = p_book_id
        and s.grade_label = v_grade
    ) then
      select max(s.season_no) into v_season_no
      from public.student_textbook_seasons s
      where s.student_id = v_student
        and s.book_id = p_book_id
        and s.grade_label = v_grade;
    else
      perform public._student_ensure_active_textbook_season(
        v_academy, v_student, p_book_id, v_grade, null
      );
      v_season_no := public._student_close_open_textbook_season(
        v_academy, v_student, p_book_id, v_grade, 'ended'
      );
    end if;
  else
    v_season_no := public._student_close_open_textbook_season(
      v_academy, v_student, p_book_id, v_grade, 'ended'
    );
  end if;

  select coalesce(
    bool_or(
      s.close_reason = 'completed'
      or coalesce((s.snapshot->'totals'->>'all_completed')::boolean, false)
      or (
        coalesce((s.snapshot->'totals'->>'book_problems')::integer, 0) > 0
        and coalesce((s.snapshot->'totals'->>'passed')::integer, 0)
            >= coalesce((s.snapshot->'totals'->>'book_problems')::integer, 0)
      )
    ),
    false
  )
  into v_ever_completed
  from public.student_textbook_seasons s
  where s.student_id = v_student
    and s.book_id = p_book_id
    and s.grade_label = v_grade;

  return jsonb_build_object(
    'ok', true,
    'season_state', 'closed',
    'season_no', coalesce(v_season_no, 1),
    'ever_completed', coalesce(v_ever_completed, false)
  );
end;
$$;

revoke all on function public.student_set_textbook_season_state_v1(uuid, text, text)
  from public;
grant execute on function public.student_set_textbook_season_state_v1(uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 8) 과제 출제 시 시작 전·보류·마감 교재를 자동으로 활성 시즌으로 맞춘다
-- ---------------------------------------------------------------------------
create or replace function public._trg_activate_season_on_homework_problems()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
begin
  for rec in
    select distinct
      n.academy_id,
      n.student_id,
      n.book_id,
      coalesce(n.grade_label, '') as grade_label
    from new_rows n
    where n.academy_id is not null
      and n.student_id is not null
      and n.book_id is not null
  loop
    perform public._student_ensure_active_textbook_season(
      rec.academy_id,
      rec.student_id,
      rec.book_id,
      rec.grade_label,
      null
    );
  end loop;
  return null;
end;
$$;

drop trigger if exists trg_activate_season_on_homework_problems
  on public.homework_item_problems;

create trigger trg_activate_season_on_homework_problems
  after insert on public.homework_item_problems
  referencing new table as new_rows
  for each statement
  execute function public._trg_activate_season_on_homework_problems();

-- ---------------------------------------------------------------------------
-- 9) 학생앱 시즌 상태 조회 RPC 확장
-- ---------------------------------------------------------------------------
drop function if exists public.student_textbook_seasons_v1();

create function public.student_textbook_seasons_v1()
returns table(
  book_id uuid,
  grade_label text,
  season_no integer,
  opened_at timestamptz,
  paused_at timestamptz,
  closed_at timestamptz,
  close_reason text,
  season_state text,
  ever_completed boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_student uuid;
begin
  select i.student_id into v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with latest as (
    select distinct on (s.book_id, s.grade_label)
      s.book_id,
      s.grade_label,
      s.season_no,
      s.opened_at,
      s.paused_at,
      s.closed_at,
      s.close_reason
    from public.student_textbook_seasons s
    where s.student_id = v_student
    order by
      s.book_id,
      s.grade_label,
      (s.closed_at is null) desc,
      s.season_no desc
  ),
  history as (
    select
      s.book_id,
      s.grade_label,
      bool_or(
        s.close_reason = 'completed'
        or coalesce((s.snapshot->'totals'->>'all_completed')::boolean, false)
        or (
          coalesce((s.snapshot->'totals'->>'book_problems')::integer, 0) > 0
          and coalesce((s.snapshot->'totals'->>'passed')::integer, 0)
              >= coalesce((s.snapshot->'totals'->>'book_problems')::integer, 0)
        )
      ) as ever_completed
    from public.student_textbook_seasons s
    where s.student_id = v_student
    group by s.book_id, s.grade_label
  )
  select
    l.book_id,
    l.grade_label,
    l.season_no,
    l.opened_at,
    l.paused_at,
    l.closed_at,
    l.close_reason,
    case
      when l.closed_at is not null then 'closed'
      when l.paused_at is not null then 'paused'
      else 'active'
    end as season_state,
    coalesce(h.ever_completed, false) as ever_completed
  from latest l
  left join history h
    on h.book_id = l.book_id
   and h.grade_label = l.grade_label;
end;
$$;

revoke all on function public.student_textbook_seasons_v1() from public;
grant execute on function public.student_textbook_seasons_v1() to authenticated;

-- ---------------------------------------------------------------------------
-- 10) 마감 직후(다음 시즌 시작 전)에도 마지막 시즌 기록·완료율이 유지되도록
--     조회 RPC들의 기준 시즌을 `열린 시즌 우선 → 최근 마감 시즌`으로 통일한다.
-- ---------------------------------------------------------------------------
drop function if exists public.student_list_textbooks();
create function public.student_list_textbooks()
returns table(
  book_id uuid,
  grade_label text,
  book_name text,
  book_description text,
  book_color integer,
  series text,
  cover_ref text,
  total_problems bigint,
  graded_count bigint,
  correct_count bigint,
  completed_count bigint,
  first_wrong_count bigint,
  corrected_count bigint,
  stage_progress jsonb,
  last_raw_page integer,
  last_display_page integer,
  last_activity timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with books as (
    select distinct l.book_id, l.grade_label
    from public.student_flows f
    join public.flow_textbook_links l
      on l.flow_id = f.id
     and l.academy_id = f.academy_id
    where f.academy_id = v_academy
      and f.student_id = v_student
      and coalesce(f.enabled, true)
  ),
  latest_seasons as (
    select distinct on (s.book_id, s.grade_label)
      s.book_id,
      s.grade_label,
      s.id as season_id,
      s.season_no,
      s.opened_at
    from public.student_textbook_seasons s
    where s.student_id = v_student
    order by
      s.book_id,
      s.grade_label,
      (s.closed_at is null) desc,
      s.season_no desc
  ),
  gradable as (
    select
      c.book_id,
      c.grade_label,
      c.id as crop_id,
      c.sub_key,
      c.raw_page,
      c.display_page,
      ls.season_id,
      coalesce(ls.season_no, 1) as season_no,
      ls.opened_at as season_opened_at
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    join books b
      on b.book_id = c.book_id
     and b.grade_label = c.grade_label
    left join latest_seasons ls
      on ls.book_id = c.book_id
     and ls.grade_label = coalesce(c.grade_label, '')
    where c.academy_id = v_academy
      and not c.is_set_header
      and (
        (
          a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null
        )
        or a.answer_kind = 'image'
      )
      and not public._student_crop_on_hold(v_student, c.id)
  ),
  season_passed as (
    select distinct g.crop_id
    from gradable g
    join public.student_problem_rounds pr
      on pr.student_id = v_student
     and pr.crop_id = g.crop_id
     and pr.passed
     and (
       (g.season_id is not null and pr.season_id = g.season_id)
       or (g.season_id is null and pr.season_id is null)
     )
  ),
  teacher_done as (
    select distinct g.crop_id
    from gradable g
    join public.homework_item_units u
      on u.academy_id = v_academy
     and u.student_id = v_student
     and u.book_id = g.book_id
     and u.grade_label = g.grade_label
    join public.homework_items h
      on h.id = u.homework_item_id
     and h.student_id = v_student
     and h.academy_id = v_academy
    where (
      h.completed_at is not null
      or coalesce(h.status, 0) = 1
      or h.confirmed_at is not null
      or coalesce(h.phase, 0) = 4
    )
    and (
      g.season_no <= 1
      or coalesce(h.completed_at, h.confirmed_at, h.created_at) >= g.season_opened_at
    )
    and (
      g.raw_page between least(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
                     and greatest(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
      or g.display_page between least(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
                            and greatest(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
    )
    union
    select distinct g.crop_id
    from gradable g
    join public.homework_item_problems hip
      on hip.academy_id = v_academy
     and hip.student_id = v_student
     and hip.crop_id = g.crop_id
     and hip.excluded_at is null
    join public.homework_items h
      on h.id = hip.homework_item_id
     and h.student_id = v_student
     and h.academy_id = v_academy
    where (
      h.completed_at is not null
      or coalesce(h.status, 0) = 1
      or (coalesce(h.phase, 0) = 4 and coalesce(h.pending_complete, false))
    )
    and coalesce(h.time_limit_minutes, 0) <= 0
    and (
      g.season_no <= 1
      or coalesce(h.completed_at, h.confirmed_at, h.created_at) >= g.season_opened_at
    )
  ),
  marked as (
    select
      g.*,
      r.id as record_id,
      (r.id is not null and coalesce(r.attempt_count, 0) > 0) as has_active_record,
      coalesce(r.is_correct, false) as is_correct,
      coalesce(r.first_attempt_correct, false) as first_attempt_correct,
      r.updated_at,
      (sp.crop_id is not null) as has_season_pass,
      (
        coalesce(r.is_correct, false)
        or sp.crop_id is not null
        or td.crop_id is not null
      ) as is_completed
    from gradable g
    left join public.student_textbook_answer_records r
      on r.crop_id = g.crop_id
     and r.student_id = v_student
    left join season_passed sp on sp.crop_id = g.crop_id
    left join teacher_done td on td.crop_id = g.crop_id
  ),
  book_stats as (
    select
      m.book_id,
      m.grade_label,
      count(*) as total_problems,
      count(*) filter (where m.has_active_record or m.has_season_pass) as graded_count,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass) and m.first_attempt_correct
      ) as correct_count,
      count(*) filter (where m.is_completed) as completed_count,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass)
          and not m.first_attempt_correct
      ) as first_wrong_count,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass)
          and not m.first_attempt_correct
          and (m.is_correct or m.has_season_pass)
      ) as corrected_count,
      max(m.updated_at) as last_activity
    from marked m
    group by m.book_id, m.grade_label
  ),
  stage_rows as (
    select
      m.book_id,
      m.grade_label,
      upper(coalesce(nullif(m.sub_key, ''), 'A')) as sub_key,
      count(*) as total,
      count(*) filter (where m.has_active_record or m.has_season_pass) as graded,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass) and m.first_attempt_correct
      ) as correct,
      count(*) filter (where m.is_completed) as completed
    from marked m
    group by m.book_id, m.grade_label,
      upper(coalesce(nullif(m.sub_key, ''), 'A'))
  ),
  stages as (
    select
      s.book_id,
      s.grade_label,
      jsonb_object_agg(
        s.sub_key,
        jsonb_build_object(
          'total', s.total,
          'graded', s.graded,
          'correct', s.correct,
          'completed', s.completed
        )
        order by s.sub_key
      ) as progress
    from stage_rows s
    group by s.book_id, s.grade_label
  ),
  last_rec as (
    select distinct on (r.book_id, r.grade_label)
      r.book_id,
      r.grade_label,
      c.raw_page,
      c.display_page
    from public.student_textbook_answer_records r
    join public.textbook_problem_crops c on c.id = r.crop_id
    where r.student_id = v_student
    order by r.book_id, r.grade_label, r.updated_at desc
  )
  select
    bs.book_id,
    bs.grade_label,
    coalesce(rf.name, '교재') as book_name,
    coalesce(rf.description, '') as book_description,
    rf.color as book_color,
    coalesce(tm.payload->>'series', '') as series,
    coalesce(cover.url, '') as cover_ref,
    bs.total_problems,
    bs.graded_count,
    bs.correct_count,
    bs.completed_count,
    bs.first_wrong_count,
    bs.corrected_count,
    coalesce(st.progress, '{}'::jsonb) as stage_progress,
    lr.raw_page as last_raw_page,
    lr.display_page as last_display_page,
    bs.last_activity
  from book_stats bs
  join public.resource_files rf on rf.id = bs.book_id
  left join public.textbook_metadata tm
    on tm.academy_id = v_academy
   and tm.book_id = bs.book_id
   and tm.grade_label = bs.grade_label
  left join stages st
    on st.book_id = bs.book_id
   and st.grade_label = bs.grade_label
  left join last_rec lr
    on lr.book_id = bs.book_id
   and lr.grade_label = bs.grade_label
  left join lateral (
    select l.url
    from public.resource_file_links l
    where l.academy_id = v_academy
      and l.file_id = bs.book_id
      and l.grade = bs.grade_label || '#cover'
      and coalesce(l.url, '') <> ''
    order by l.created_at desc
    limit 1
  ) cover on true
  order by coalesce(rf.name, '교재');
end;
$$;

revoke all on function public.student_list_textbooks() from public;
grant execute on function public.student_list_textbooks() to authenticated;

drop function if exists public.student_textbook_page_problems_v2(uuid, text, integer);
create function public.student_textbook_page_problems_v2(
  p_book_id uuid,
  p_grade_label text,
  p_raw_page integer
) returns table(
  crop_id uuid,
  problem_number text,
  label text,
  answer_kind text,
  grading_mode text,
  my_answer text,
  my_correct boolean,
  attempt_count integer,
  graded_by text,
  flags text[],
  report_status text,
  set_parts jsonb,
  part_results jsonb,
  category_code text,
  category_label text,
  item_name text,
  round_no integer,
  round_open boolean,
  content_group_kind text,
  content_group_label text,
  content_group_title text,
  passed_before integer,
  round_revision_count integer,
  latest_passed boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_season_id uuid;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select s.id into v_season_id
  from public.student_textbook_seasons s
  where s.student_id = v_student
    and s.book_id = p_book_id
    and s.grade_label = coalesce(p_grade_label, '')
  order by (s.closed_at is null) desc, s.season_no desc
  limit 1;

  return query
  select
    c.id,
    c.problem_number,
    c.label,
    a.answer_kind,
    public._student_grading_mode(
      a.answer_kind, coalesce(a.answer_text, a.answer_latex_2d)
    ),
    r.last_answer,
    r.is_correct,
    r.attempt_count,
    r.graded_by,
    r.flags,
    report.status,
    case when a.answer_kind = 'subjective' then (
      select jsonb_agg(
        jsonb_build_object(
          'key', part ->> 'key',
          'mode', public._student_grading_mode(
            'subjective', part ->> 'text'
          )
        )
      )
      from jsonb_array_elements(
        coalesce(a.sub_answers -> 'parts', '[]'::jsonb)
      ) as part
      where coalesce(part ->> 'key', '') <> ''
    ) end,
    case when a.answer_kind = 'subjective' then r.part_results end,
    c.category_code,
    pc.display_label,
    c.item_name,
    coalesce(rd.season_round_no, 0),
    coalesce(rd.is_open, false),
    c.content_group_kind,
    c.content_group_label,
    c.content_group_title,
    coalesce(rd.passed_before, 0),
    coalesce(rd.round_revision_count, 0),
    coalesce(rd.latest_passed, false)
  from public.textbook_problem_crops c
  join public.textbook_problem_answers a on a.crop_id = c.id
  left join public.student_textbook_answer_records r
    on r.crop_id = c.id and r.student_id = v_student
  left join public.textbook_metadata tm
    on tm.academy_id = c.academy_id
   and tm.book_id = c.book_id
   and tm.grade_label = c.grade_label
  left join public.textbook_problem_categories pc
    on pc.series_key = lower(coalesce(tm.payload->>'series', ''))
   and pc.category_code = c.category_code
  left join lateral (
    select s.status
    from public.student_textbook_problem_reports s
    where s.student_id = v_student
      and s.crop_id = c.id
    order by
      case s.status when 'open' then 0 when 'accepted' then 1 else 2 end,
      s.created_at desc
    limit 1
  ) report on true
  left join lateral (
    select
      (
        select count(*)::integer
        from public.student_problem_rounds sr
        where sr.student_id = pr.student_id
          and sr.crop_id = pr.crop_id
          and (
            (v_season_id is not null and sr.season_id = v_season_id)
            or (v_season_id is null and sr.season_id is null)
          )
      ) as season_round_no,
      pr.closed_at is null as is_open,
      pr.passed as latest_passed,
      (
        select count(*)::integer
        from public.student_problem_rounds older
        where older.student_id = pr.student_id
          and older.crop_id = pr.crop_id
          and older.round_no < pr.round_no
          and older.passed
          and (
            (v_season_id is not null and older.season_id = v_season_id)
            or (v_season_id is null and older.season_id is null)
          )
      ) as passed_before,
      (
        select count(*)::integer
        from public.learning_attempts la
        where la.round_id = pr.id
          and la.result in ('correct', 'wrong', 'partial')
      ) as round_revision_count
    from public.student_problem_rounds pr
    where pr.student_id = v_student
      and pr.crop_id = c.id
      and (
        (v_season_id is not null and pr.season_id = v_season_id)
        or (v_season_id is null and pr.season_id is null)
      )
    order by pr.round_no desc
    limit 1
  ) rd on true
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label
    and c.raw_page = p_raw_page
    and not c.is_set_header
    and (
      (
        a.answer_kind in ('objective', 'subjective')
        and coalesce(a.answer_text, a.answer_latex_2d) is not null
      )
      or a.answer_kind = 'image'
    )
  order by
    case when c.problem_number ~ '^\d+$'
      then c.problem_number::integer else 2147483647 end,
    c.problem_number;
end;
$$;

revoke all on function public.student_textbook_page_problems_v2(uuid, text, integer)
  from public;
grant execute on function public.student_textbook_page_problems_v2(uuid, text, integer)
  to authenticated;

create or replace function public.textbook_resolved_unit_tree(
  p_book_id uuid,
  p_grade_label text
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_season_id uuid;
  v_series text;
  v_page_offset integer;
  v_units jsonb;
  v_categories jsonb;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  select s.id into v_season_id
  from public.student_textbook_seasons s
  where s.student_id = v_student
    and s.book_id = p_book_id
    and s.grade_label = coalesce(p_grade_label, '')
  order by (s.closed_at is null) desc, s.season_no desc
  limit 1;

  select
    lower(coalesce(tm.payload->>'series', '')),
    tm.page_offset
  into v_series, v_page_offset
  from public.textbook_metadata tm
  where tm.academy_id = v_academy
    and tm.book_id = p_book_id
    and tm.grade_label = p_grade_label;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'code', pc.category_code,
        'label', pc.display_label,
        'order_index', pc.order_index
      ) order by pc.order_index
    ),
    '[]'::jsonb
  )
  into v_categories
  from public.textbook_problem_categories pc
  where pc.series_key = v_series
    and pc.is_active;

  with season_passed as (
    select distinct pr.crop_id
    from public.student_problem_rounds pr
    where pr.student_id = v_student
      and pr.book_id = p_book_id
      and pr.grade_label is not distinct from coalesce(p_grade_label, '')
      and pr.passed
      and (
        (v_season_id is not null and pr.season_id = v_season_id)
        or (v_season_id is null and pr.season_id is null)
      )
  ),
  page_stats as (
    select
      c.unit_id,
      c.raw_page,
      max(c.display_page) as display_page,
      count(*) filter (where held.crop_id is null) as total,
      count(*) filter (
        where held.crop_id is null
          and (
            (r.id is not null and coalesce(r.attempt_count, 0) > 0)
            or sp.crop_id is not null
          )
      ) as graded,
      count(*) filter (
        where held.crop_id is null
          and (coalesce(r.is_correct, false) or sp.crop_id is not null)
      ) as correct,
      count(*) filter (where held.crop_id is not null) as reported
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    left join public.student_textbook_answer_records r
      on r.crop_id = c.id
     and r.student_id = v_student
    left join season_passed sp on sp.crop_id = c.id
    left join lateral (
      select report.crop_id
      from public.student_textbook_problem_reports report
      where report.student_id = v_student
        and report.crop_id = c.id
        and report.status in ('open', 'accepted')
      limit 1
    ) held on true
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
      and c.unit_id is not null
      and not c.is_set_header
      and (
        (
          a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null
        )
        or a.answer_kind = 'image'
      )
    group by c.unit_id, c.raw_page
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', big.id,
        'unit_key', big.unit_key,
        'name', big.name,
        'order_index', big.order_index,
        'start_page', big.display_start_page,
        'end_page', big.display_end_page,
        'mids', (
          select coalesce(
            jsonb_agg(
              jsonb_build_object(
                'id', mid.id,
                'unit_key', mid.unit_key,
                'name', mid.name,
                'order_index', mid.order_index,
                'start_page', mid.display_start_page,
                'end_page', mid.display_end_page,
                'smalls', (
                  select coalesce(
                    jsonb_agg(
                      jsonb_build_object(
                        'id', small.id,
                        'unit_key', small.unit_key,
                        'name', small.name,
                        'order_index', small.order_index,
                        'legacy_sub_key', small.legacy_sub_key,
                        'start_page', small.display_start_page,
                        'end_page', small.display_end_page,
                        'pages', (
                          select coalesce(
                            jsonb_agg(
                              jsonb_build_object(
                                'raw_page', ps.raw_page,
                                'display_page', ps.display_page,
                                'total', ps.total,
                                'graded', ps.graded,
                                'correct', ps.correct,
                                'reported', ps.reported
                              )
                              order by ps.raw_page
                            ),
                            '[]'::jsonb
                          )
                          from page_stats ps
                          where ps.unit_id = small.id
                        )
                      )
                      order by small.order_index, small.id
                    ),
                    '[]'::jsonb
                  )
                  from public.textbook_units small
                  where small.parent_id = mid.id
                    and small.unit_level = 'small'
                )
              )
              order by mid.order_index, mid.id
            ),
            '[]'::jsonb
          )
          from public.textbook_units mid
          where mid.parent_id = big.id
            and mid.unit_level = 'mid'
        )
      )
      order by big.order_index, big.id
    ),
    '[]'::jsonb
  )
  into v_units
  from public.textbook_units big
  where big.academy_id = v_academy
    and big.book_id = p_book_id
    and big.grade_label = p_grade_label
    and big.unit_level = 'big';

  return jsonb_build_object(
    'schema_version', 2,
    'book_id', p_book_id,
    'grade_label', p_grade_label,
    'series', coalesce(v_series, ''),
    'page_offset', v_page_offset,
    'categories', coalesce(v_categories, '[]'::jsonb),
    'category_catalog', coalesce(v_categories, '[]'::jsonb),
    'units', coalesce(v_units, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.textbook_resolved_unit_tree(uuid, text) from public;
grant execute on function public.textbook_resolved_unit_tree(uuid, text) to authenticated;

create or replace function public.student_textbook_unit_tree(
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
  v_season_id uuid;
  v_payload jsonb;
  v_page_offset integer;
  v_pages jsonb;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select s.id into v_season_id
  from public.student_textbook_seasons s
  where s.student_id = v_student
    and s.book_id = p_book_id
    and s.grade_label = coalesce(p_grade_label, '')
  order by (s.closed_at is null) desc, s.season_no desc
  limit 1;

  select t.payload, t.page_offset into v_payload, v_page_offset
  from public.textbook_metadata t
  where t.academy_id = v_academy
    and t.book_id = p_book_id
    and t.grade_label = p_grade_label;

  with season_passed as (
    select distinct pr.crop_id
    from public.student_problem_rounds pr
    where pr.student_id = v_student
      and pr.book_id = p_book_id
      and pr.grade_label is not distinct from coalesce(p_grade_label, '')
      and pr.passed
      and (
        (v_season_id is not null and pr.season_id = v_season_id)
        or (v_season_id is null and pr.season_id is null)
      )
  )
  select coalesce(jsonb_agg(row_to_json(p) order by p.big_order, p.mid_order, p.sub_key, p.raw_page), '[]'::jsonb)
  into v_pages
  from (
    select
      c.big_order, c.mid_order, c.sub_key,
      c.raw_page,
      max(c.display_page) as display_page,
      count(*) filter (where h.crop_id is null) as total,
      count(*) filter (
        where h.crop_id is null
          and (
            (r.id is not null and coalesce(r.attempt_count, 0) > 0)
            or sp.crop_id is not null
          )
      ) as graded,
      count(*) filter (
        where h.crop_id is null
          and (coalesce(r.is_correct, false) or sp.crop_id is not null)
      ) as correct,
      count(*) filter (where h.crop_id is not null) as reported
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    left join public.student_textbook_answer_records r
      on r.crop_id = c.id and r.student_id = v_student
    left join season_passed sp on sp.crop_id = c.id
    left join lateral (
      select s.crop_id
      from public.student_textbook_problem_reports s
      where s.student_id = v_student
        and s.crop_id = c.id
        and s.status in ('open', 'accepted')
      limit 1
    ) h on true
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
      and not c.is_set_header
      and (
        (a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null)
        or a.answer_kind = 'image'
      )
    group by c.big_order, c.mid_order, c.sub_key, c.raw_page
  ) p;

  return jsonb_build_object(
    'payload', coalesce(v_payload, '{}'::jsonb),
    'page_offset', v_page_offset,
    'pages', v_pages
  );
end;
$$;

revoke all on function public.student_textbook_unit_tree(uuid, text) from public;
grant execute on function public.student_textbook_unit_tree(uuid, text) to authenticated;

create or replace function public.staff_textbook_season_problem_stats_v1(
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text default ''
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_grade text := coalesce(p_grade_label, '');
  v_season_id uuid;
  v_season_no integer := 1;
  v_season_opened_at timestamptz;
  v_problems jsonb;
begin
  select s.academy_id into v_academy
  from public.students s
  where s.id = p_student_id;

  if v_academy is null or p_book_id is null then
    return jsonb_build_object(
      'ok', false,
      'season_no', 1,
      'problems', '[]'::jsonb
    );
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_textbook_season_problem_stats_v1: forbidden';
  end if;

  select s.id, s.season_no, s.opened_at
    into v_season_id, v_season_no, v_season_opened_at
  from public.student_textbook_seasons s
  where s.student_id = p_student_id
    and s.book_id = p_book_id
    and s.grade_label = v_grade
  order by (s.closed_at is null) desc, s.season_no desc
  limit 1;

  v_season_no := coalesce(v_season_no, 1);

  with book_crops as (
    select
      c.id as crop_id,
      c.pb_question_uid
    from public.textbook_problem_crops c
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = v_grade
      and not c.is_set_header
  ),
  assigned_events as (
    select
      bc.crop_id,
      coalesce(gi.group_id::text, hi.id::text) as event_key,
      (
        hi.completed_at is not null
        or coalesce(hi.status, 0) = 1
        or hi.confirmed_at is not null
        or coalesce(hi.phase, 0) = 4
      ) as item_completed
    from book_crops bc
    join public.homework_item_problems hip
      on hip.academy_id = v_academy
     and hip.student_id = p_student_id
     and (
       hip.crop_id = bc.crop_id
       or (
         bc.pb_question_uid is not null
         and hip.pb_question_uid = bc.pb_question_uid
       )
     )
    join public.homework_items hi
      on hi.id = hip.homework_item_id
     and hi.academy_id = v_academy
    left join public.homework_group_items gi
      on gi.homework_item_id = hi.id
     and gi.academy_id = v_academy
    where coalesce(hi.status, 0) <> 9
      and (
        v_season_no <= 1
        or v_season_opened_at is null
        or hi.created_at >= v_season_opened_at
      )
  ),
  standalone_exam_events as (
    select
      bc.crop_id,
      'session:' || ls.id::text as event_key,
      bool_or(la.result = 'correct') as exam_correct
    from book_crops bc
    join public.learning_attempts la
      on la.academy_id = v_academy
     and la.student_id = p_student_id
     and la.homework_item_problem_id is null
     and (
       la.crop_id = bc.crop_id
       or (
         bc.pb_question_uid is not null
         and la.pb_question_uid = bc.pb_question_uid
       )
     )
    join public.learning_sessions ls
      on ls.id = la.session_id
     and ls.academy_id = v_academy
     and ls.homework_group_id is null
     and ls.session_kind in ('daily_test', 'monthly_exam')
    where (
      v_season_no <= 1
      or v_season_opened_at is null
      or la.attempted_at >= v_season_opened_at
    )
    group by bc.crop_id, ls.id
  ),
  tried_agg as (
    select
      t.crop_id,
      count(distinct t.event_key)::integer as tried_count,
      count(distinct t.event_key) filter (where t.done)::integer as hw_done_count
    from (
      select ae.crop_id, ae.event_key, ae.item_completed as done
      from assigned_events ae
      union all
      select se.crop_id, se.event_key, se.exam_correct as done
      from standalone_exam_events se
    ) t
    group by t.crop_id
  ),
  round_pass_agg as (
    select
      bc.crop_id,
      count(*) filter (where pr.passed)::integer as passed_rounds
    from book_crops bc
    join public.student_problem_rounds pr
      on pr.student_id = p_student_id
     and pr.academy_id = v_academy
     and pr.crop_id = bc.crop_id
    where (
      (v_season_id is not null and pr.season_id = v_season_id)
      or (v_season_id is null and pr.season_id is null)
    )
    group by bc.crop_id
  ),
  exam_pass_agg as (
    select
      bc.crop_id,
      count(distinct ls.id)::integer as passed_exams
    from book_crops bc
    join public.learning_attempts la
      on la.academy_id = v_academy
     and la.student_id = p_student_id
     and la.round_id is null
     and la.result = 'correct'
     and (
       la.crop_id = bc.crop_id
       or (
         bc.pb_question_uid is not null
         and la.pb_question_uid = bc.pb_question_uid
       )
     )
    join public.learning_sessions ls
      on ls.id = la.session_id
     and ls.academy_id = v_academy
     and ls.session_kind in ('daily_test', 'monthly_exam')
    where (
      v_season_no <= 1
      or v_season_opened_at is null
      or la.attempted_at >= v_season_opened_at
    )
    group by bc.crop_id
  ),
  merged as (
    select
      bc.crop_id,
      coalesce(ta.tried_count, 0) as tried_count,
      greatest(
        coalesce(rpa.passed_rounds, 0) + coalesce(epa.passed_exams, 0),
        coalesce(ta.hw_done_count, 0)
      )::integer as completed_count
    from book_crops bc
    left join tried_agg ta on ta.crop_id = bc.crop_id
    left join round_pass_agg rpa on rpa.crop_id = bc.crop_id
    left join exam_pass_agg epa on epa.crop_id = bc.crop_id
    where coalesce(ta.tried_count, 0) > 0
       or coalesce(rpa.passed_rounds, 0) > 0
       or coalesce(epa.passed_exams, 0) > 0
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'crop_id', m.crop_id,
        'tried_count', m.tried_count,
        'completed_count', m.completed_count
      )
    ),
    '[]'::jsonb
  )
  into v_problems
  from merged m;

  return jsonb_build_object(
    'ok', true,
    'season_no', v_season_no,
    'season_opened_at', v_season_opened_at,
    'problems', v_problems
  );
end;
$$;

revoke all on function public.staff_textbook_season_problem_stats_v1(uuid, uuid, text)
  from public;
grant execute on function public.staff_textbook_season_problem_stats_v1(uuid, uuid, text)
  to authenticated;
