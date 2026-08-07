-- Migrated-homework grading: "abandoned" means the question is removed from
-- the current assignment scope while its grading/history row remains.

alter table public.homework_item_problems
  add column if not exists excluded_at timestamptz,
  add column if not exists exclusion_reason text;

alter table public.homework_test_grading_attempt_items
  drop constraint if exists hw_test_grading_attempt_items_state_chk;

alter table public.homework_test_grading_attempt_items
  add constraint hw_test_grading_attempt_items_state_chk
    check (state in ('correct', 'wrong', 'not_performed', 'abandoned'));

create or replace function public._normalize_homework_grading_item_state()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.state = 'unsolved' then
    new.state := 'wrong';
    new.incorrect_kind := 'blank';
  elsif new.state = 'wrong' and new.incorrect_kind is null then
    new.incorrect_kind := 'answered';
  elsif new.state <> 'wrong' then
    new.incorrect_kind := null;
  end if;
  if new.baseline_state = 'unsolved' then
    new.baseline_state := 'wrong';
  end if;
  return new;
end;
$$;

-- A fully abandoned main question is soft-removed from homework_item_problems.
-- Partial set-question abandonment remains in part_states, so the parent
-- question stays assigned until every part is abandoned.
create or replace function public._exclude_abandoned_homework_problem()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_problem_ref text;
begin
  if new.state <> 'abandoned' then
    return new;
  end if;

  -- PB keys carry question_uid explicitly. Migrated textbook keys end with the
  -- crop UUID (`homeworkId|page|number|cropId`), so support both forms.
  v_problem_ref := nullif(btrim(coalesce(new.question_uid, '')), '');
  if v_problem_ref is null then
    v_problem_ref := nullif(
      substring(
        new.question_key
        from '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$'
      ),
      ''
    );
  end if;
  if v_problem_ref is null then
    return new;
  end if;

  update public.homework_item_problems p
     set excluded_at = coalesce(p.excluded_at, now()),
         exclusion_reason = 'teacher_abandoned',
         updated_at = now()
   where p.academy_id = new.academy_id
     and p.homework_item_id = new.homework_item_id
     and (
       p.pb_question_uid::text = v_problem_ref
       or p.crop_id::text = v_problem_ref
     )
     and p.excluded_at is null;

  update public.homework_items h
     set count = (
           select count(*)::integer
           from public.homework_item_problems p
           where p.academy_id = h.academy_id
             and p.homework_item_id = h.id
             and p.excluded_at is null
         ),
         updated_at = now()
   where h.academy_id = new.academy_id
     and h.id = new.homework_item_id;

  return new;
end;
$$;

drop trigger if exists trg_exclude_abandoned_homework_problem
  on public.homework_test_grading_attempt_items;
create trigger trg_exclude_abandoned_homework_problem
after insert or update of state
on public.homework_test_grading_attempt_items
for each row execute function public._exclude_abandoned_homework_problem();

-- Student app: excluded questions are no longer part of the current
-- assignment, but their learning/grading history remains queryable.
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
    p.id,
    coalesce(hi.title, ''),
    coalesce(gi.item_order_index, 0),
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
    coalesce(p.source_stage, 'original'),
    coalesce(a.has_correct, false),
    coalesce(a.attempts, 0)::integer,
    a.last_result,
    a.last_attempted_at
  from public.homework_group_items gi
  join public.homework_items hi
    on hi.id = gi.homework_item_id
   and hi.academy_id = gi.academy_id
  join public.homework_item_problems p
    on p.homework_item_id = hi.id
   and p.academy_id = hi.academy_id
   and p.excluded_at is null
  left join lateral (
    select
      bool_or(la.result = 'correct') as has_correct,
      count(*) as attempts,
      (array_agg(la.result order by la.attempted_at desc))[1] as last_result,
      (array_agg(la.attempted_at order by la.attempted_at desc))[1]
        as last_attempted_at
    from public.learning_attempts la
    where la.homework_item_problem_id = p.id
  ) a on true
  where gi.group_id = p_group_id
    and gi.academy_id = v_academy
    and gi.student_id = v_student
  order by coalesce(gi.item_order_index, 0), p.sort_order;
end;
$$;

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
      and p.excluded_at is null
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
   and p.excluded_at is null
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
