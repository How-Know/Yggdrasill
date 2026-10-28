-- 숙제 배정을 문항 단위로 기록한다.
--
-- homework_assignments 행 하나가 숙제 한 번이다. 배정 시점에 그 과제 문항 중
-- 아직 정답 기록이 없는 문항(학생앱 오답만 재출제와 같은 기준)을 고정해 둔다.
-- 나중에 문항을 풀어도 "그날 어떤 문항이 나갔는지"가 바뀌지 않는다.
--
-- 과제 문항 스냅샷(homework_item_problems)은 과제를 고칠 때 지우고 다시 만든다.
-- 그래서 crop_id 를 함께 저장하고, 아직 검사 전인 배정만 새 스냅샷으로 다시 맞춘다.
-- 쓰기는 트리거로만 한다(learning-records.md §11).

create table if not exists public.homework_assignment_problems (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  assignment_id uuid not null
    references public.homework_assignments(id) on delete cascade,
  homework_item_id uuid not null
    references public.homework_items(id) on delete cascade,
  homework_item_problem_id uuid
    references public.homework_item_problems(id) on delete set null,
  crop_id uuid references public.textbook_problem_crops(id) on delete set null,
  pb_question_uid uuid,
  sort_order integer not null default 0,
  assigned_at timestamptz not null,
  source text not null default 'assign'
    check (source in ('assign', 'backfill')),
  created_at timestamptz not null default now(),
  constraint homework_assignment_problems_assignment_crop_key
    unique (assignment_id, crop_id)
);

create index if not exists idx_hw_assignment_problems_student
  on public.homework_assignment_problems (student_id);
create index if not exists idx_hw_assignment_problems_academy_student_time
  on public.homework_assignment_problems (academy_id, student_id, assigned_at desc);
create index if not exists idx_hw_assignment_problems_item_crop
  on public.homework_assignment_problems (homework_item_id, crop_id);
create index if not exists idx_hw_assignment_problems_hip
  on public.homework_assignment_problems (homework_item_problem_id)
  where homework_item_problem_id is not null;
create index if not exists idx_hw_assignment_problems_crop_time
  on public.homework_assignment_problems (crop_id, assigned_at desc)
  where crop_id is not null;

alter table public.homework_assignment_problems enable row level security;

drop policy if exists homework_assignment_problems_staff_select
  on public.homework_assignment_problems;
create policy homework_assignment_problems_staff_select
  on public.homework_assignment_problems
  for select
  using (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = homework_assignment_problems.academy_id
        and m.user_id = auth.uid()
    )
  );

comment on table public.homework_assignment_problems is
  '숙제 배정 × 문항. 배정 시점에 정답 기록이 없던 문항을 고정한다. 검사 전 배정만 과제 문항 스냅샷 변경을 따라간다.';
comment on column public.homework_assignment_problems.source is
  'assign = 배정 트리거, backfill = 도입 시점에 열려 있던 배정을 배정 시각 기준으로 채운 것.';

-- 배정 하나의 문항 묶음을 지금 스냅샷으로 다시 만든다.
create or replace function public._homework_assignment_sync_problems(
  p_assignment_id uuid,
  p_source text default 'assign'
)
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  delete from public.homework_assignment_problems hap
  where hap.assignment_id = p_assignment_id;

  insert into public.homework_assignment_problems (
    academy_id,
    student_id,
    assignment_id,
    homework_item_id,
    homework_item_problem_id,
    crop_id,
    pb_question_uid,
    sort_order,
    assigned_at,
    source
  )
  select
    a.academy_id,
    a.student_id,
    a.id,
    a.homework_item_id,
    p.id,
    p.crop_id,
    p.pb_question_uid,
    p.sort_order,
    a.assigned_at,
    p_source
  from public.homework_assignments a
  join public.homework_item_problems p
    on p.homework_item_id = a.homework_item_id
   and p.academy_id = a.academy_id
   and p.excluded_at is null
  where a.id = p_assignment_id
    and a.student_id is not null
    and not exists (
      select 1
      from public.learning_attempts la
      where la.homework_item_problem_id = p.id
        and la.result = 'correct'
        and la.attempted_at <= a.assigned_at
    )
  on conflict (assignment_id, crop_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public._homework_assignment_sync_problems(uuid, text)
  from public, anon, authenticated;

create or replace function public._homework_assignment_freeze_problems()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._homework_assignment_sync_problems(new.id, 'assign');
  return null;
end;
$$;

revoke all on function public._homework_assignment_freeze_problems()
  from public, anon, authenticated;

drop trigger if exists trg_homework_assignment_freeze_problems
  on public.homework_assignments;
create trigger trg_homework_assignment_freeze_problems
  after insert on public.homework_assignments
  for each row execute function public._homework_assignment_freeze_problems();

-- 과제 문항 스냅샷이 바뀌면, 아직 한 번도 검사하지 않은 배정만 다시 맞춘다.
-- 검사가 끝난 배정은 당시 묶음을 그대로 둔다.
create or replace function public._homework_item_problems_resync_open_assignments()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assignment_id uuid;
begin
  for v_assignment_id in
    select a.id
    from public.homework_assignments a
    where a.homework_item_id in (
        select distinct n.homework_item_id from new_rows n
      )
      and a.status = 'assigned'
      and not exists (
        select 1
        from public.homework_assignment_checks c
        where c.assignment_id = a.id
      )
  loop
    perform public._homework_assignment_sync_problems(v_assignment_id, 'assign');
  end loop;
  return null;
end;
$$;

revoke all on function public._homework_item_problems_resync_open_assignments()
  from public, anon, authenticated;

drop trigger if exists trg_homework_item_problems_resync_open_assignments
  on public.homework_item_problems;
create trigger trg_homework_item_problems_resync_open_assignments
  after insert on public.homework_item_problems
  referencing new table as new_rows
  for each statement
  execute function public._homework_item_problems_resync_open_assignments();

-- 도입 시점에 아직 검사 전인 배정은 배정 시각 기준으로 채운다.
do $backfill$
declare
  v_assignment_id uuid;
begin
  for v_assignment_id in
    select a.id
    from public.homework_assignments a
    where a.status = 'assigned'
      and not exists (
        select 1
        from public.homework_assignment_checks c
        where c.assignment_id = a.id
      )
      and not exists (
        select 1
        from public.homework_assignment_problems hap
        where hap.assignment_id = a.id
      )
  loop
    perform public._homework_assignment_sync_problems(v_assignment_id, 'backfill');
  end loop;
end;
$backfill$;

-- 퇴원 정리 목록에 새 기록 테이블(이 테이블과 알림장 확정본)을 넣는다.
do $purge$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(
    'public._purge_withdrawn_student_step(uuid, timestamptz, integer)'::regprocedure
  )
  into v_definition;
  v_definition := replace(v_definition, E'\r', '');

  if strpos(v_definition, '''homework_assignment_problems''') > 0 then
    return;
  end if;

  v_old := $old$  v_tables constant text[] := array[
    'learning_attempts',$old$;
  v_new := $new$  v_tables constant text[] := array[
    'homework_assignment_problems',
    'student_class_session_todo_sheet_snapshots',
    'learning_attempts',$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'PURGE_WITHDRAWN_STUDENT_TABLES_SOURCE_MISMATCH';
  end if;
  execute replace(v_definition, v_old, v_new);
end;
$purge$;

-- 알림장 학습 기록: 오늘 첫 검사한 숙제의 "푼 문항 / 나간 문항".
alter table public.student_class_session_snapshots
  add column if not exists homework_problem_total integer,
  add column if not exists homework_problem_solved integer;

comment on column public.student_class_session_snapshots.homework_problem_total is
  '오늘 첫 검사한 숙제 배정에 고정된 문항 수(homework_assignment_problems). 문항 기록이 있는 배정이 없으면 null.';
comment on column public.student_class_session_snapshots.homework_problem_solved is
  'homework_problem_total 중 배정 뒤 첫 기록이 맞음·틀림·부분인 문항 수. 숙제 안 함·남김 검사는 검사 전 기록만 본다.';

do $compute$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(
    'public._lesson_record_compute(uuid)'::regprocedure
  )
  into v_definition;
  v_definition := replace(v_definition, E'\r', '');

  -- 변수
  v_old := $old$  v_avg_tries numeric;
$old$;
  v_new := $new$  v_avg_tries numeric;
  v_hw_problem_total integer;
  v_hw_problem_solved integer;
$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_HW_PROBLEMS_DECLARE_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  -- 계산: Flow 진도 계산 바로 앞에 넣는다.
  v_old := $old$  -- Flow·교재별 진도.
$old$;
  v_new := $new$  -- 숙제로 푼 문항: 오늘 첫 검사한 숙제 배정(등원 전 배정)의 고정 문항 중
  -- 배정 뒤 첫 기록이 맞음·틀림·부분인 문항. 미수행(skipped)은 풀지 않은 것이다.
  -- 숙제 안 함·남김 검사는 검사 뒤 채점이 수업 풀이이므로 검사 전 기록만 본다.
  with first_checks as (
    select distinct on (c.assignment_id)
      c.assignment_id,
      c.checked_at,
      coalesce(c.outcome, 'graded') in ('not_done', 'left_behind') as not_done
    from public.homework_assignment_checks c
    join public.homework_assignments a
      on a.id = c.assignment_id
     and a.academy_id = c.academy_id
     and a.student_id = c.student_id
    where c.academy_id = v_ar.academy_id
      and c.student_id = v_ar.student_id
      and a.assigned_at < v_start
      and c.checked_at >= v_day_start
      and c.checked_at < v_day_end
      and not exists (
        select 1
        from public.homework_assignment_checks p
        where p.assignment_id = c.assignment_id
          and p.checked_at < c.checked_at
      )
    order by c.assignment_id, c.checked_at, c.id
  ),
  assigned as (
    select
      hap.homework_item_id,
      hap.crop_id,
      hap.assigned_at,
      fc.checked_at,
      fc.not_done
    from public.homework_assignment_problems hap
    join first_checks fc on fc.assignment_id = hap.assignment_id
    where hap.crop_id is not null
  ),
  first_record as (
    select
      s.*,
      (
        select la.result
        from public.learning_attempts la
        left join public.homework_item_problems hip
          on hip.id = la.homework_item_problem_id
        left join public.learning_sessions ls on ls.id = la.session_id
        where la.academy_id = v_ar.academy_id
          and la.student_id = v_ar.student_id
          and la.crop_id = s.crop_id
          and coalesce(hip.homework_item_id, ls.homework_item_id)
            = s.homework_item_id
          and la.attempted_at >= s.assigned_at
          and la.attempted_at <= case when s.not_done then s.checked_at else v_end end
          and la.result in ('correct', 'wrong', 'partial', 'skipped')
        order by la.attempted_at, la.id
        limit 1
      ) as first_result
    from assigned s
  )
  select
    case when count(*) > 0 then count(*)::integer end,
    case when count(*) > 0 then (count(*) filter (
      where fr.first_result in ('correct', 'wrong', 'partial')
    ))::integer end
  into v_hw_problem_total, v_hw_problem_solved
  from first_record fr;

  -- Flow·교재별 진도.
$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_HW_PROBLEMS_BLOCK_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  -- 반환값
  v_old := $old$    'assignment_basis', v_assignment_basis,
$old$;
  v_new := $new$    'assignment_basis', v_assignment_basis,
    'homework_problem_total', v_hw_problem_total,
    'homework_problem_solved', v_hw_problem_solved,
$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_HW_PROBLEMS_RETURN_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$    'version', 4,$old$;
  v_new := $new$    'version', 5,$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_HW_PROBLEMS_VERSION_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  execute v_definition;
end;
$compute$;

do $refresh$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(
    'public._lesson_record_refresh(uuid)'::regprocedure
  )
  into v_definition;
  v_definition := replace(v_definition, E'\r', '');

  v_old := $old$      assignment_basis = v_record->>'assignment_basis',
$old$;
  v_new := $new$      assignment_basis = v_record->>'assignment_basis',
      homework_problem_total = (v_record->>'homework_problem_total')::integer,
      homework_problem_solved = (v_record->>'homework_problem_solved')::integer,
$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_REFRESH_HW_PROBLEMS_MISMATCH';
  end if;
  execute replace(v_definition, v_old, v_new);
end;
$refresh$;
