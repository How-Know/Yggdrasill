-- 수업 기록 요약 (알림장 "오늘의 학습 기록")
--
-- 새 수업 단위 테이블을 만들지 않고, 하원 시 출결마다 남는
-- student_class_session_snapshots 에 요약 숫자를 붙인다.
-- 기존 수행률 컬럼은 하원 시점 값으로 고정된 채로 두고, 아래 lesson record
-- 컬럼만 원자료에서 다시 계산할 수 있다(알림장 재출력·스태프 갱신).
-- 판정(정상/확인/주의)은 숫자가 충분히 쌓인 뒤 따로 정한다. 여기서는 만들지 않는다.
-- 설계: docs/architecture/learning-records.md §12

-- pre_done 마이그레이션(20260601161200)보다 먼저 적용돼도 계산 함수가 동작하도록 한다.
alter table public.homework_items
  add column if not exists pre_done_progress integer,
  add column if not exists pre_done_at timestamptz,
  add column if not exists pre_done_issue_type text,
  add column if not exists pre_done_issue_note text;

-- ---------------------------------------------------------------------------
-- 1) 스냅샷 요약 컬럼
-- ---------------------------------------------------------------------------
alter table public.student_class_session_snapshots
  add column if not exists solved_problem_count integer,
  add column if not exists first_try_correct_count integer,
  add column if not exists correction_required_count integer,
  add column if not exists correction_success_count integer,
  add column if not exists problem_record_coverage text,
  add column if not exists homework_total integer,
  add column if not exists homework_completed integer,
  add column if not exists assignment_total integer,
  add column if not exists assignment_completed integer,
  add column if not exists assignment_basis text,
  add column if not exists lesson_record_version integer,
  add column if not exists lesson_record_computed_at timestamptz;

alter table public.student_class_session_snapshots
  add column if not exists correction_success_rate numeric(5, 4)
    generated always as (
      case
        when correction_required_count > 0
          then round(
            least(correction_success_count, correction_required_count)::numeric
              / correction_required_count,
            4
          )
      end
    ) stored;

alter table public.student_class_session_snapshots
  drop constraint if exists student_class_session_snapshot_lesson_record_chk;
alter table public.student_class_session_snapshots
  add constraint student_class_session_snapshot_lesson_record_chk check (
    (problem_record_coverage is null
      or problem_record_coverage in ('full', 'partial', 'none'))
    and (assignment_basis is null
      or assignment_basis in ('goal_snapshot', 'session_plan', 'none'))
    and coalesce(solved_problem_count, 0) >= 0
    and coalesce(first_try_correct_count, 0) >= 0
    and coalesce(correction_required_count, 0) >= 0
    and coalesce(correction_success_count, 0) >= 0
    and coalesce(homework_total, 0) >= 0
    and coalesce(homework_completed, 0) >= 0
    and coalesce(assignment_total, 0) >= 0
    and coalesce(assignment_completed, 0) >= 0
  );

comment on column public.student_class_session_snapshots.solved_problem_count is
  '수업 시간(등원~하원)에 푼 문항 수: 수업 과제 문항 + 숙제 오답을 다시 풀어 본 문항. null = 문항 기록 없음.';
comment on column public.student_class_session_snapshots.first_try_correct_count is
  '수업 과제 문항 중 이번 회차 첫 채점이 수업 시간 안에 있었고 정답인 문항 수.';
comment on column public.student_class_session_snapshots.correction_required_count is
  '수업 시간 안에 처음 채점되어 틀린 문항 수(수업 과제 + 숙제).';
comment on column public.student_class_session_snapshots.correction_success_count is
  'correction_required_count 중 하원까지 정답이 나온 문항 수.';
comment on column public.student_class_session_snapshots.problem_record_coverage is
  '대상 과제 중 문항 단위 기록(homework_item_problems)이 있는 비율: full / partial / none.';
comment on column public.student_class_session_snapshots.homework_total is
  '오늘 검사 대상 숙제 그룹 수(자발 추가검사만 있는 그룹 제외). 알림장 검사내역과 같은 기준.';
comment on column public.student_class_session_snapshots.homework_completed is
  'homework_total 중 오늘 진행률이 100% 이상인 그룹 수. 검사 기록이 없고 오늘 완료된 과제는 100%로 본다.';
comment on column public.student_class_session_snapshots.assignment_total is
  '오늘 수업 과제 그룹 수. 목표 제시 스냅샷이 있으면 그것, 없으면 수업별 과제 계획의 오늘(in_class) 과제.';
comment on column public.student_class_session_snapshots.assignment_basis is
  'assignment_total 의 근거: goal_snapshot / session_plan / none.';

-- ---------------------------------------------------------------------------
-- 2) Flow별 진도
-- ---------------------------------------------------------------------------
create table if not exists public.student_class_session_snapshot_flows (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  snapshot_id uuid not null
    references public.student_class_session_snapshots(id) on delete cascade,
  flow_id uuid references public.student_flows(id) on delete set null,
  flow_name_snapshot text not null default '',
  progress_state text not null,
  class_item_count integer not null default 0,
  completed_item_count integer not null default 0,
  textbook_total_problems integer,
  textbook_completed_problems integer,
  progress_percent numeric(5, 2) generated always as (
    case
      when textbook_total_problems > 0
        then round(
          least(textbook_completed_problems, textbook_total_problems)::numeric
            * 100 / textbook_total_problems,
          2
        )
    end
  ) stored,
  created_at timestamptz not null default now(),
  constraint student_class_session_snapshot_flows_state_chk
    check (progress_state in ('completed', 'in_progress')),
  constraint student_class_session_snapshot_flows_counts_chk check (
    class_item_count >= 0
    and completed_item_count >= 0
    and coalesce(textbook_total_problems, 0) >= 0
    and coalesce(textbook_completed_problems, 0) >= 0
  )
);

comment on table public.student_class_session_snapshot_flows is
  '수업 스냅샷의 Flow별 진도. progress_percent 는 Flow 에 문항 단위 교재가 연결된 경우만 계산된다.';

create index if not exists idx_class_session_snapshot_flows_snapshot
  on public.student_class_session_snapshot_flows (snapshot_id);
create index if not exists idx_class_session_snapshot_flows_student
  on public.student_class_session_snapshot_flows (student_id);
create index if not exists idx_class_session_snapshot_flows_academy
  on public.student_class_session_snapshot_flows (academy_id);
create index if not exists idx_class_session_snapshot_flows_flow
  on public.student_class_session_snapshot_flows (flow_id)
  where flow_id is not null;

alter table public.student_class_session_snapshot_flows enable row level security;

drop policy if exists student_class_session_snapshot_flows_staff_select
  on public.student_class_session_snapshot_flows;
create policy student_class_session_snapshot_flows_staff_select
on public.student_class_session_snapshot_flows
for select
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = student_class_session_snapshot_flows.academy_id
      and m.user_id = auth.uid()
  )
);

-- ---------------------------------------------------------------------------
-- 3) Flow 교재 진도 (학생앱 교재 카드와 같은 완료 기준)
-- ---------------------------------------------------------------------------
create or replace function public._lesson_record_flow_textbook_progress(
  p_academy_id uuid,
  p_student_id uuid,
  p_flow_id uuid
)
returns table(total_problems integer, completed_problems integer)
language sql
stable
security definer
set search_path = public
as $$
  with books as (
    select distinct l.book_id, l.grade_label
    from public.flow_textbook_links l
    where l.academy_id = p_academy_id
      and l.flow_id = p_flow_id
  ),
  gradable as (
    select distinct
      c.id as crop_id,
      c.book_id,
      c.grade_label,
      c.raw_page,
      c.display_page
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    join books b
      on b.book_id = c.book_id
     and b.grade_label = c.grade_label
    where c.academy_id = p_academy_id
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
      g.raw_page between least(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
                     and greatest(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
      or g.display_page between least(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
                            and greatest(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
    )
  )
  select
    count(*)::integer,
    count(*) filter (
      where coalesce(r.is_correct, false) or td.crop_id is not null
    )::integer
  from gradable g
  left join public.student_textbook_answer_records r
    on r.crop_id = g.crop_id
   and r.student_id = p_student_id
  left join teacher_done td on td.crop_id = g.crop_id;
$$;

revoke all on function public._lesson_record_flow_textbook_progress(uuid, uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4) 계산 (저장하지 않음)
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

  -- Flow별 진도: 오늘 수업 과제 기준.
  with class_items as (
    select
      h.id,
      coalesce(h.flow_id, g.flow_id) as flow_id,
      h.completed_at
    from unnest(v_class_items) x(item_id)
    join public.homework_items h on h.id = x.item_id
    left join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.academy_id = h.academy_id
    left join public.homework_groups g on g.id = gi.group_id
  ),
  per_flow as (
    select
      f.id as flow_id,
      f.name as flow_name,
      coalesce(f.order_index, 0) as order_index,
      count(*)::integer as item_count,
      count(*) filter (
        where ci.completed_at >= v_start and ci.completed_at <= v_end
      )::integer as completed_count
    from class_items ci
    join public.student_flows f
      on f.id = ci.flow_id
     and f.student_id = v_ar.student_id
    group by f.id, f.name, f.order_index
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'flow_id', pf.flow_id,
      'flow_name', pf.flow_name,
      'progress_state',
        case when pf.completed_count >= pf.item_count
          then 'completed' else 'in_progress' end,
      'class_item_count', pf.item_count,
      'completed_item_count', pf.completed_count,
      'textbook_total_problems',
        case when tp.total_problems > 0 then tp.total_problems end,
      'textbook_completed_problems',
        case when tp.total_problems > 0 then tp.completed_problems end
    )
    order by pf.order_index, pf.flow_name
  ), '[]'::jsonb)
  into v_flows
  from per_flow pf
  left join lateral public._lesson_record_flow_textbook_progress(
    v_ar.academy_id,
    v_ar.student_id,
    pf.flow_id
  ) tp on true;

  return jsonb_build_object(
    'version', 1,
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
-- 5) 스냅샷에 저장
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
    progress_state,
    class_item_count,
    completed_item_count,
    textbook_total_problems,
    textbook_completed_problems
  )
  select
    v_snapshot.academy_id,
    v_snapshot.student_id,
    v_snapshot.id,
    nullif(e.value->>'flow_id', '')::uuid,
    coalesce(e.value->>'flow_name', ''),
    e.value->>'progress_state',
    coalesce((e.value->>'class_item_count')::integer, 0),
    coalesce((e.value->>'completed_item_count')::integer, 0),
    (e.value->>'textbook_total_problems')::integer,
    (e.value->>'textbook_completed_problems')::integer
  from jsonb_array_elements(coalesce(v_record->'flows', '[]'::jsonb)) e(value);

  return true;
end;
$$;

revoke all on function public._lesson_record_refresh(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6) 스태프 RPC
-- ---------------------------------------------------------------------------
create or replace function public.staff_lesson_record_v1(p_attendance_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
begin
  select ar.academy_id into v_academy
  from public.attendance_records ar
  where ar.id = p_attendance_id;
  if v_academy is null then
    return null;
  end if;
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_lesson_record_v1: forbidden';
  end if;
  return public._lesson_record_compute(p_attendance_id);
end;
$$;

revoke all on function public.staff_lesson_record_v1(uuid) from public, anon;
grant execute on function public.staff_lesson_record_v1(uuid) to authenticated;

create or replace function public.staff_refresh_lesson_record_v1(p_attendance_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
begin
  select ar.academy_id into v_academy
  from public.attendance_records ar
  where ar.id = p_attendance_id;
  if v_academy is null then
    return false;
  end if;
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_refresh_lesson_record_v1: forbidden';
  end if;
  return public._lesson_record_refresh(p_attendance_id);
end;
$$;

revoke all on function public.staff_refresh_lesson_record_v1(uuid) from public, anon;
grant execute on function public.staff_refresh_lesson_record_v1(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7) 하원 트리거: 스냅샷 직후 요약 계산
-- ---------------------------------------------------------------------------
-- trg_finalize_class_session_on_departure 는 이름순으로 trg_homework_reset_on_departure
-- 보다 먼저 돈다. 그래서 plan_details 는 오늘→숙제 이월 전 상태로 남는다.
create or replace function public._finalize_class_session_on_departure()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.departure_time is not null
     and old.departure_time is null
     and new.arrival_time is not null then
    begin
      perform public.m5_finalize_class_session_snapshot(new.id);
    exception when others then
      raise warning
        'class session snapshot failed attendance=% error=%',
        new.id,
        sqlerrm;
    end;
    begin
      perform public._lesson_record_refresh(new.id);
    exception when others then
      raise warning
        'lesson record refresh failed attendance=% error=%',
        new.id,
        sqlerrm;
    end;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8) 퇴원 정리 목록에 새 테이블 추가
-- ---------------------------------------------------------------------------
create or replace function public._purge_withdrawn_student_step(
  p_student_id uuid,
  p_deadline timestamptz,
  p_batch integer default 500
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Leaf tables first so each batch cascades into as little as possible.
  -- Every table here already has student_id ... on delete cascade.
  v_tables constant text[] := array[
    'learning_attempts',
    'learning_exposures',
    'learning_range_timings',
    'learning_sessions',
    'student_problem_rounds',
    'homework_test_grading_attempt_items',
    'homework_test_grading_attempts',
    'homework_study_intervals',
    'homework_item_problems',
    'homework_item_pages',
    'homework_item_units',
    'homework_session_plan_items',
    'homework_assignment_checks',
    'homework_assignments',
    'homework_group_items',
    'homework_group_runtime',
    'homework_groups',
    'student_textbook_answer_records',
    'student_textbook_problem_reports',
    'student_handwriting_samples',
    'student_grading_equiv_logs',
    'student_class_session_snapshot_flows',
    'student_class_session_snapshots',
    'attendance_notification_logs',
    'attendance_notification_queue',
    'makeup_notification_logs',
    'makeup_notification_queue',
    'watch_push_events',
    'student_charge_points',
    'attendance_records',
    'student_point_ledger'
  ];
  v_table text;
  v_deleted integer;
  v_any_deleted boolean := false;
begin
  if not exists (
    select 1 from public.students s
    where s.id = p_student_id and s.withdrawn_at is not null
  ) then
    return true;
  end if;

  if not pg_try_advisory_xact_lock(hashtext('purge_withdrawn_student'), hashtext(p_student_id::text)) then
    return false;
  end if;

  foreach v_table in array v_tables loop
    loop
      if clock_timestamp() >= p_deadline then
        return false;
      end if;
      if v_table = 'student_point_ledger' then
        -- The ledger blocks UPDATE, so a row still referenced by a reversal
        -- cannot go first (its SET NULL would be an update).
        delete from public.student_point_ledger l
        where l.ctid = any(array(
          select x.ctid from public.student_point_ledger x
          where x.student_id = p_student_id
            and not exists (
              select 1 from public.student_point_ledger r where r.reverses_id = x.id
            )
          limit p_batch
        ));
      else
        execute format(
          'delete from public.%I t where t.ctid = any(array(select x.ctid from public.%I x where x.student_id = $1 limit $2))',
          v_table, v_table
        ) using p_student_id, p_batch;
      end if;
      get diagnostics v_deleted = row_count;
      exit when v_deleted = 0;
      v_any_deleted := true;
    end loop;
  end loop;

  -- The final delete gets a fresh call so it never shares a timeout with batches.
  if v_any_deleted then
    return false;
  end if;

  delete from public.students s
  where s.id = p_student_id and s.withdrawn_at is not null;
  return true;
end;
$$;

revoke all on function public._purge_withdrawn_student_step(uuid, timestamptz, integer)
  from public, anon, authenticated;
