-- 수업 기록 요약: Flow 진도를 교재 단위로 나누고, 수업 전 완료분과 오늘 완료분을 구분한다.
--
-- 행 단위가 (Flow) → (Flow, 교재)로 바뀐다. 교재는 오늘 수업 과제의 homework_items.book_id 이다.
-- 교재가 없는 과제만 있는 Flow 는 교재 없는 행 하나로 남는다.
-- 완료 시각: 학생앱 정답은 first_correct_at, 선생님 완료는 completed_at(없으면 confirmed_at).
-- 시각이 없는 옛 완료 기록은 수업 전 완료로 본다(오늘 한 것으로 부풀리지 않는다).
-- 설계: docs/architecture/learning-records.md §12

alter table public.student_class_session_snapshot_flows
  add column if not exists book_id uuid references public.resource_files(id) on delete set null,
  add column if not exists grade_label text,
  add column if not exists book_name_snapshot text,
  add column if not exists textbook_completed_before integer;

create index if not exists idx_class_session_snapshot_flows_book
  on public.student_class_session_snapshot_flows (book_id)
  where book_id is not null;

alter table public.student_class_session_snapshot_flows
  drop constraint if exists student_class_session_snapshot_flows_before_chk;
alter table public.student_class_session_snapshot_flows
  add constraint student_class_session_snapshot_flows_before_chk
  check (coalesce(textbook_completed_before, 0) >= 0);

comment on table public.student_class_session_snapshot_flows is
  '수업 스냅샷의 Flow·교재별 진도. 교재 문항 진도는 수업 시작 전 완료(textbook_completed_before)와 하원까지 완료(textbook_completed_problems)를 함께 둔다.';
comment on column public.student_class_session_snapshot_flows.textbook_completed_before is
  '등원 전에 완료된 교재 문항 수. 오늘 늘어난 문항 = textbook_completed_problems - 이 값.';
comment on column public.student_class_session_snapshot_flows.textbook_completed_problems is
  '하원(하원 전이면 계산 시점)까지 완료된 교재 문항 수.';

-- ---------------------------------------------------------------------------
-- 교재 진도 (학생앱 교재 카드와 같은 완료 기준 + 완료 시각)
-- ---------------------------------------------------------------------------
create or replace function public._lesson_record_book_progress(
  p_academy_id uuid,
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_start timestamptz,
  p_end timestamptz
)
returns table(total_problems integer, completed_before integer, completed_by_end integer)
language sql
stable
security definer
set search_path = public
as $$
  with gradable as (
    select distinct
      c.id as crop_id,
      c.raw_page,
      c.display_page
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    where c.academy_id = p_academy_id
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
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
  teacher_done as (
    select
      g.crop_id,
      min(coalesce(h.completed_at, h.confirmed_at)) as done_at,
      bool_or(coalesce(h.completed_at, h.confirmed_at) is null) as untimed
    from gradable g
    join public.homework_item_units u
      on u.academy_id = p_academy_id
     and u.student_id = p_student_id
     and u.book_id = p_book_id
     and u.grade_label = p_grade_label
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
      g.raw_page between least(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
                     and greatest(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
      or g.display_page between least(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
                            and greatest(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
    )
    group by g.crop_id
  ),
  per_crop as (
    select
      coalesce(
        (r.is_correct and (r.first_correct_at is null or r.first_correct_at < p_start))
        or (td.crop_id is not null and (td.untimed or td.done_at < p_start)),
        false
      ) as done_before,
      coalesce(
        (r.is_correct and (r.first_correct_at is null or r.first_correct_at <= p_end))
        or (td.crop_id is not null and (td.untimed or td.done_at <= p_end)),
        false
      ) as done_by_end
    from gradable g
    left join public.student_textbook_answer_records r
      on r.crop_id = g.crop_id
     and r.student_id = p_student_id
    left join teacher_done td on td.crop_id = g.crop_id
  )
  select
    count(*)::integer,
    count(*) filter (where done_before)::integer,
    count(*) filter (where done_by_end or done_before)::integer
  from per_crop;
$$;

revoke all on function public._lesson_record_book_progress(uuid, uuid, uuid, text, timestamptz, timestamptz)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 계산 (v2: Flow 행을 교재 단위로)
-- ---------------------------------------------------------------------------
create or replace function public._lesson_record_compute(p_attendance_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ar public.attendance_records%rowtype;
  v_start timestamptz;
  v_end timestamptz;
  v_day date;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_has_snapshot boolean := false;
  v_assignment_basis text := 'none';
  v_assignment_total integer := 0;
  v_assignment_completed integer := 0;
  v_class_items uuid[] := '{}'::uuid[];
  v_homework_total integer := 0;
  v_homework_completed integer := 0;
  v_homework_items uuid[] := '{}'::uuid[];
  v_scope_items integer := 0;
  v_tracked_items integer := 0;
  v_coverage text := 'none';
  v_solved integer;
  v_first_try integer;
  v_correction_required integer;
  v_correction_success integer;
  v_flows jsonb := '[]'::jsonb;
begin
  select * into v_ar
  from public.attendance_records ar
  where ar.id = p_attendance_id;
  if not found then
    return null;
  end if;

  v_start := coalesce(v_ar.arrival_time, v_ar.class_date_time);
  if v_start is null then
    return null;
  end if;
  v_end := greatest(v_start, coalesce(v_ar.departure_time, now()));
  v_day := (coalesce(v_ar.class_date_time, v_start) at time zone 'Asia/Seoul')::date;
  v_day_start := v_day::timestamp at time zone 'Asia/Seoul';
  v_day_end := v_day_start + interval '1 day';

  -- 과제: 목표 제시 스냅샷 우선, 없으면 수업별 과제 계획의 오늘(in_class).
  -- 하원 뒤에는 오늘→숙제 이월로 계획 행의 destination 이 바뀌므로,
  -- 하원 직전에 찍힌 스냅샷의 plan_details 를 읽는다.
  if v_ar.homework_plan_snapshot_at is not null
     and jsonb_typeof(v_ar.homework_plan_snapshot_groups) = 'array'
     and jsonb_array_length(v_ar.homework_plan_snapshot_groups) > 0 then
    v_assignment_basis := 'goal_snapshot';
    with plan_groups as (
      select array(
        select x::uuid
        from jsonb_array_elements_text(g.value -> 'item_ids') x
      ) as item_ids
      from jsonb_array_elements(v_ar.homework_plan_snapshot_groups) g(value)
      where jsonb_typeof(g.value -> 'item_ids') = 'array'
        and jsonb_array_length(g.value -> 'item_ids') > 0
    )
    select
      count(*)::integer,
      count(*) filter (
        where (
          select count(*)
          from unnest(pg.item_ids) iid(item_id)
          join public.homework_items h
            on h.id = iid.item_id
           and h.student_id = v_ar.student_id
          where h.completed_at >= v_ar.homework_plan_snapshot_at
            and h.completed_at <= v_end
        ) = cardinality(pg.item_ids)
      )::integer,
      coalesce((
        select array_agg(distinct i)
        from plan_groups p2
        cross join unnest(p2.item_ids) i
      ), '{}'::uuid[])
    into v_assignment_total, v_assignment_completed, v_class_items
    from plan_groups pg;
  else
    v_has_snapshot := exists (
      select 1
      from public.student_class_session_snapshots s
      where s.attendance_id = v_ar.id
    );
    with plan_rows as (
      select
        (e.value->>'homework_item_id')::uuid as item_id,
        coalesce(
          nullif(e.value->>'group_id', '')::uuid,
          (e.value->>'homework_item_id')::uuid
        ) as group_key
      from public.student_class_session_snapshots s
      cross join lateral jsonb_array_elements(
        coalesce(s.plan_details, '[]'::jsonb)
      ) e(value)
      where v_has_snapshot
        and s.attendance_id = v_ar.id
        and e.value->>'destination' = 'in_class'
        and coalesce(e.value->>'resolution', '')
          in ('pending', 'confirmed', 'completed')
        and nullif(e.value->>'homework_item_id', '') is not null

      union

      select
        spi.homework_item_id,
        coalesce(spi.group_id, gi.group_id, spi.homework_item_id)
      from public.homework_session_plan_items spi
      left join public.homework_group_items gi
        on gi.homework_item_id = spi.homework_item_id
       and gi.academy_id = spi.academy_id
      where not v_has_snapshot
        and spi.source_attendance_id = v_ar.id
        and spi.destination = 'in_class'
        and spi.resolution in ('pending', 'confirmed', 'completed')
    ),
    plan_groups as (
      select pr.group_key, array_agg(distinct pr.item_id) as item_ids
      from plan_rows pr
      group by pr.group_key
    )
    select
      count(*)::integer,
      count(*) filter (
        where (
          select count(*)
          from unnest(pg.item_ids) iid(item_id)
          join public.homework_items h on h.id = iid.item_id
          where h.completed_at >= v_start
            and h.completed_at <= v_end
        ) = cardinality(pg.item_ids)
      )::integer,
      coalesce((
        select array_agg(distinct i)
        from plan_groups p2
        cross join unnest(p2.item_ids) i
      ), '{}'::uuid[])
    into v_assignment_total, v_assignment_completed, v_class_items
    from plan_groups pg;
    if v_assignment_total > 0 then
      v_assignment_basis := 'session_plan';
    end if;
  end if;

  -- 숙제: 알림장 검사내역(homework_assign_dialog.dart)과 같은 포함·진행률 기준.
  with grp_link as (
    select gi.homework_item_id as item_id, gi.group_id
    from public.homework_group_items gi
    join public.homework_groups g
      on g.id = gi.group_id
     and g.status = 'active'
    where gi.academy_id = v_ar.academy_id
      and gi.student_id = v_ar.student_id
  ),
  due as (
    select
      a.homework_item_id as item_id,
      (array_agg(
        least(150, greatest(0, coalesce(a.progress, 0)))
        order by a.assigned_at desc, a.id desc
      ))[1] as latest_progress,
      bool_or(btrim(coalesce(a.note, '')) <> '__self_extra_check__') as has_regular
    from public.homework_assignments a
    where a.academy_id = v_ar.academy_id
      and a.student_id = v_ar.student_id
      and coalesce((a.due_at at time zone 'Asia/Seoul')::date, a.due_date) = v_day
    group by a.homework_item_id
  ),
  chk as (
    select
      c.homework_item_id as item_id,
      least(150, greatest(0, coalesce(
        max(c.progress) filter (where c.checked_at < v_day_start), 0
      ))) as prev_progress,
      least(150, greatest(0, coalesce(
        max(c.progress) filter (
          where c.checked_at >= v_day_start and c.checked_at < v_day_end
        ), 0
      ))) as today_progress,
      bool_or(c.checked_at >= v_day_start and c.checked_at < v_day_end) as has_today
    from public.homework_assignment_checks c
    where c.academy_id = v_ar.academy_id
      and c.student_id = v_ar.student_id
    group by c.homework_item_id
  ),
  cand as (
    select
      h.id as item_id,
      coalesce(gl.group_id, h.id) as group_key,
      gl.group_id is not null as in_group,
      h.completed_at,
      greatest(0, coalesce(h.pre_done_progress, 0)) as pre_done,
      d.item_id is not null as has_due,
      coalesce(d.latest_progress, 0) as due_progress,
      coalesce(d.has_regular, false) as due_regular,
      coalesce(c.has_today, false) as has_today,
      coalesce(c.prev_progress, 0) as prev_progress,
      greatest(coalesce(c.today_progress, 0), coalesce(c.prev_progress, 0))
        as window_progress
    from public.homework_items h
    left join grp_link gl on gl.item_id = h.id
    left join due d on d.item_id = h.id
    left join chk c on c.item_id = h.id
    where h.academy_id = v_ar.academy_id
      and h.student_id = v_ar.student_id
  ),
  included as (
    select
      c.item_id,
      c.group_key,
      case
        when c.has_due then c.due_regular
        when c.has_today then true
        else false
      end as is_regular,
      case
        when not c.has_today
             and c.completed_at >= v_day_start
             and c.completed_at < v_day_end
          then greatest(
            100,
            case
              when c.has_due then greatest(c.prev_progress, c.due_progress)
              else greatest(c.window_progress, c.pre_done)
            end
          )
        when c.has_due and c.has_today
          then greatest(c.window_progress, c.due_progress)
        when c.has_due then greatest(c.prev_progress, c.due_progress)
        when c.has_today then c.window_progress
        else greatest(c.window_progress, c.pre_done)
      end as current_progress
    from cand c
    where c.has_due
       or c.has_today
       or (c.in_group and c.pre_done > 0)
  ),
  hw_groups as (
    select
      i.group_key,
      bool_or(i.is_regular) as is_regular,
      max(i.current_progress) as current_progress
    from included i
    group by i.group_key
  )
  select
    count(*) filter (where hg.is_regular)::integer,
    count(*) filter (where hg.is_regular and hg.current_progress >= 100)::integer,
    coalesce((select array_agg(distinct i.item_id) from included i), '{}'::uuid[])
  into v_homework_total, v_homework_completed, v_homework_items
  from hw_groups hg;

  -- 문항 기록 범위
  select
    count(*)::integer,
    count(*) filter (
      where exists (
        select 1
        from public.homework_item_problems p
        where p.homework_item_id = x.item_id
      )
    )::integer
  into v_scope_items, v_tracked_items
  from (
    select distinct unnest(v_class_items || v_homework_items) as item_id
  ) x;

  v_coverage := case
    when v_tracked_items <= 0 then 'none'
    when v_tracked_items < v_scope_items then 'partial'
    else 'full'
  end;

  if v_coverage <> 'none' then
    with scoped as (
      select
        la.crop_id,
        la.round_id,
        la.attempted_at,
        coalesce(hip.homework_item_id, ls.homework_item_id) = any(v_class_items)
          as is_class,
        coalesce(hip.homework_item_id, ls.homework_item_id) = any(v_homework_items)
          as is_homework
      from public.learning_attempts la
      left join public.homework_item_problems hip
        on hip.id = la.homework_item_problem_id
      left join public.learning_sessions ls on ls.id = la.session_id
      where la.academy_id = v_ar.academy_id
        and la.student_id = v_ar.student_id
        and la.attempted_at >= v_start
        and la.attempted_at <= v_end
        and la.crop_id is not null
        and la.result in ('correct', 'wrong', 'partial')
        and coalesce(hip.homework_item_id, ls.homework_item_id)
          = any(v_class_items || v_homework_items)
    ),
    touched as (
      select s.round_id, s.crop_id, bool_or(s.is_class) as is_class
      from scoped s
      where s.round_id is not null
      group by s.round_id, s.crop_id
    ),
    round_first as (
      select distinct on (la.round_id)
        la.round_id,
        la.result as first_result,
        la.attempted_at as first_at
      from public.learning_attempts la
      where la.round_id in (select t.round_id from touched t)
        and la.result in ('correct', 'wrong', 'partial')
      order by la.round_id, la.attempted_at, la.id
    ),
    round_pass as (
      select la.round_id, min(la.attempted_at) as first_correct_at
      from public.learning_attempts la
      where la.round_id in (select t.round_id from touched t)
        and la.result = 'correct'
        and la.attempted_at <= v_end
      group by la.round_id
    ),
    solved as (
      select s.crop_id
      from scoped s
      where s.is_class
      union
      select s.crop_id
      from scoped s
      where s.is_homework
        and s.round_id is not null
        and exists (
          select 1
          from public.learning_attempts p
          where p.round_id = s.round_id
            and p.attempted_at < s.attempted_at
            and p.result in ('wrong', 'partial')
        )
    )
    select
      (select count(*) from solved)::integer,
      (
        select count(distinct t.crop_id)
        from touched t
        join round_first f on f.round_id = t.round_id
        where t.is_class
          and f.first_result = 'correct'
          and f.first_at >= v_start
      )::integer,
      (
        select count(distinct t.crop_id)
        from touched t
        join round_first f on f.round_id = t.round_id
        where f.first_result in ('wrong', 'partial')
          and f.first_at >= v_start
      )::integer,
      (
        select count(distinct t.crop_id)
        from touched t
        join round_first f on f.round_id = t.round_id
        join round_pass rp on rp.round_id = t.round_id
        where f.first_result in ('wrong', 'partial')
          and f.first_at >= v_start
          and rp.first_correct_at > f.first_at
      )::integer
    into v_solved, v_first_try, v_correction_required, v_correction_success;
  end if;

  -- Flow·교재별 진도: 오늘 수업 과제 기준.
  with class_items as (
    select
      h.id,
      coalesce(h.flow_id, g.flow_id) as flow_id,
      h.book_id,
      nullif(btrim(coalesce(h.grade_label, '')), '') as grade_label,
      h.completed_at
    from unnest(v_class_items) x(item_id)
    join public.homework_items h on h.id = x.item_id
    left join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.academy_id = h.academy_id
    left join public.homework_groups g on g.id = gi.group_id
  ),
  per_book as (
    select
      f.id as flow_id,
      f.name as flow_name,
      coalesce(f.order_index, 0) as order_index,
      ci.book_id,
      case when ci.book_id is not null then ci.grade_label end as grade_label,
      count(distinct ci.id)::integer as item_count,
      count(distinct ci.id) filter (
        where ci.completed_at >= v_start and ci.completed_at <= v_end
      )::integer as completed_count
    from class_items ci
    join public.student_flows f
      on f.id = ci.flow_id
     and f.student_id = v_ar.student_id
    group by f.id, f.name, f.order_index, ci.book_id,
      case when ci.book_id is not null then ci.grade_label end
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'flow_id', pb.flow_id,
      'flow_name', pb.flow_name,
      'book_id', pb.book_id,
      'grade_label', pb.grade_label,
      'book_name', rf.name,
      'progress_state',
        case when pb.completed_count >= pb.item_count
          then 'completed' else 'in_progress' end,
      'class_item_count', pb.item_count,
      'completed_item_count', pb.completed_count,
      'textbook_total_problems',
        case when tp.total_problems > 0 then tp.total_problems end,
      'textbook_completed_before',
        case when tp.total_problems > 0 then tp.completed_before end,
      'textbook_completed_problems',
        case when tp.total_problems > 0 then tp.completed_by_end end
    )
    order by pb.order_index, pb.flow_name, rf.name nulls last, pb.grade_label
  ), '[]'::jsonb)
  into v_flows
  from per_book pb
  left join public.resource_files rf on rf.id = pb.book_id
  left join lateral public._lesson_record_book_progress(
    v_ar.academy_id,
    v_ar.student_id,
    pb.book_id,
    pb.grade_label,
    v_start,
    v_end
  ) tp on pb.book_id is not null and pb.grade_label is not null;

  return jsonb_build_object(
    'version', 2,
    'attendance_id', v_ar.id,
    'student_id', v_ar.student_id,
    'lesson_date', v_day,
    'window_start', v_start,
    'window_end', v_end,
    'is_live', v_ar.departure_time is null,
    'solved_problem_count', v_solved,
    'first_try_correct_count', v_first_try,
    'correction_required_count', v_correction_required,
    'correction_success_count', v_correction_success,
    'problem_record_coverage', v_coverage,
    'homework_total', v_homework_total,
    'homework_completed', v_homework_completed,
    'assignment_total', v_assignment_total,
    'assignment_completed', v_assignment_completed,
    'assignment_basis', v_assignment_basis,
    'flows', v_flows
  );
end;
$$;

revoke all on function public._lesson_record_compute(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 저장 (교재 컬럼 추가)
-- ---------------------------------------------------------------------------
create or replace function public._lesson_record_refresh(p_attendance_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_snapshot public.student_class_session_snapshots%rowtype;
  v_record jsonb;
begin
  select * into v_snapshot
  from public.student_class_session_snapshots s
  where s.attendance_id = p_attendance_id
  for update;
  if not found then
    return false;
  end if;

  v_record := public._lesson_record_compute(p_attendance_id);
  if v_record is null then
    return false;
  end if;

  update public.student_class_session_snapshots s
  set solved_problem_count = (v_record->>'solved_problem_count')::integer,
      first_try_correct_count = (v_record->>'first_try_correct_count')::integer,
      correction_required_count = (v_record->>'correction_required_count')::integer,
      correction_success_count = (v_record->>'correction_success_count')::integer,
      problem_record_coverage = v_record->>'problem_record_coverage',
      homework_total = (v_record->>'homework_total')::integer,
      homework_completed = (v_record->>'homework_completed')::integer,
      assignment_total = (v_record->>'assignment_total')::integer,
      assignment_completed = (v_record->>'assignment_completed')::integer,
      assignment_basis = v_record->>'assignment_basis',
      lesson_record_version = (v_record->>'version')::integer,
      lesson_record_computed_at = now(),
      updated_at = now()
  where s.id = v_snapshot.id;

  delete from public.student_class_session_snapshot_flows f
  where f.snapshot_id = v_snapshot.id;

  insert into public.student_class_session_snapshot_flows (
    academy_id,
    student_id,
    snapshot_id,
    flow_id,
    flow_name_snapshot,
    book_id,
    grade_label,
    book_name_snapshot,
    progress_state,
    class_item_count,
    completed_item_count,
    textbook_total_problems,
    textbook_completed_before,
    textbook_completed_problems
  )
  select
    v_snapshot.academy_id,
    v_snapshot.student_id,
    v_snapshot.id,
    nullif(e.value->>'flow_id', '')::uuid,
    coalesce(e.value->>'flow_name', ''),
    nullif(e.value->>'book_id', '')::uuid,
    e.value->>'grade_label',
    e.value->>'book_name',
    e.value->>'progress_state',
    coalesce((e.value->>'class_item_count')::integer, 0),
    coalesce((e.value->>'completed_item_count')::integer, 0),
    (e.value->>'textbook_total_problems')::integer,
    (e.value->>'textbook_completed_before')::integer,
    (e.value->>'textbook_completed_problems')::integer
  from jsonb_array_elements(coalesce(v_record->'flows', '[]'::jsonb)) e(value);

  return true;
end;
$$;

revoke all on function public._lesson_record_refresh(uuid)
  from public, anon, authenticated;

drop function if exists public._lesson_record_flow_textbook_progress(uuid, uuid, uuid);
