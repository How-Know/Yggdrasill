-- Student withdrawal in two phases.
--
-- A single `delete from students` cascades into every learning record the
-- student ever produced and runs past the 8s request timeout for long-time
-- students. Withdrawal is therefore split:
--
--  1) withdraw_student: archive + mark `withdrawn_at` in one short transaction.
--     RLS hides withdrawn students from every staff client read, and the rows
--     that drive live screens (time blocks, overrides, future planned
--     attendance, M5 binding, student app login) are removed right away.
--  2) purge: learning/homework rows are deleted in bounded batches (leaf tables
--     first), then the students row itself. The client triggers it right after
--     withdrawal; the cron job below finishes whatever is left.
--
-- The end state equals the old hard delete: every table listed in the purge
-- already cascades from students, and homework_items/tag_events keep their
-- rows with student_id set to null through the existing FKs.

alter table public.students
  add column if not exists withdrawn_at timestamptz,
  add column if not exists withdrawn_by uuid;

create index if not exists idx_students_withdrawn_at
  on public.students (withdrawn_at)
  where withdrawn_at is not null;

drop policy if exists students_all on public.students;
create policy students_all on public.students for all
using (
  withdrawn_at is null
  and exists (
    select 1 from public.memberships s
    where s.academy_id = students.academy_id and s.user_id = auth.uid()
  )
)
with check (
  withdrawn_at is null
  and exists (
    select 1 from public.memberships s
    where s.academy_id = students.academy_id and s.user_id = auth.uid()
  )
);

-- 1) withdraw -----------------------------------------------------------------

create or replace function public.withdraw_student(
  p_academy_id uuid,
  p_student_id uuid
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_archive_id uuid;
  v_withdrawn_at timestamptz;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if auth.uid() is null or not exists (
    select 1 from public.memberships m
    where m.academy_id = p_academy_id and m.user_id = auth.uid()
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select s.withdrawn_at into v_withdrawn_at
  from public.students s
  where s.academy_id = p_academy_id and s.id = p_student_id
  for update;
  if not found then
    raise exception 'student not found (academy_id=%, student_id=%)', p_academy_id, p_student_id
      using errcode = 'P0002';
  end if;

  if v_withdrawn_at is not null then
    select sa.id into v_archive_id
    from public.student_archives sa
    where sa.academy_id = p_academy_id and sa.student_id = p_student_id
    order by sa.archived_at desc
    limit 1;
    return v_archive_id;
  end if;

  v_archive_id := public.archive_student(p_academy_id, p_student_id);

  update public.students
  set withdrawn_at = now(), withdrawn_by = auth.uid()
  where id = p_student_id;

  update public.m5_device_bindings
  set active = false, unbound_at = now(), updated_at = now()
  where academy_id = p_academy_id and student_id = p_student_id and active;

  delete from public.student_signup_codes where student_id = p_student_id;
  delete from public.student_app_accounts where student_id = p_student_id;
  delete from public.session_overrides
  where academy_id = p_academy_id and student_id = p_student_id;
  delete from public.student_time_blocks
  where academy_id = p_academy_id and student_id = p_student_id;
  delete from public.attendance_records ar
  where ar.academy_id = p_academy_id
    and ar.student_id = p_student_id
    and ar.is_planned
    and ar.arrival_time is null
    and ar.departure_time is null
    and coalesce(ar.date, (ar.class_date_time at time zone 'Asia/Seoul')::date) >= v_today;

  return v_archive_id;
end;
$$;

revoke all on function public.withdraw_student(uuid, uuid) from public, anon;
grant execute on function public.withdraw_student(uuid, uuid) to authenticated;

-- 2) purge --------------------------------------------------------------------

-- One bounded unit of purge work. Returns true when the students row is gone
-- (or there is nothing to purge). Never touches a student that is not withdrawn.
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

-- Client-side fast path, called right after withdraw_student. Each call stays
-- well under the 8s request timeout; the client repeats until it returns true.
create or replace function public.purge_withdrawn_student(
  p_academy_id uuid,
  p_student_id uuid
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.memberships m
    where m.academy_id = p_academy_id and m.user_id = auth.uid()
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.students s
    where s.id = p_student_id and s.academy_id = p_academy_id
  ) then
    return true;
  end if;

  return public._purge_withdrawn_student_step(
    p_student_id,
    clock_timestamp() + interval '3 seconds'
  );
end;
$$;

revoke all on function public.purge_withdrawn_student(uuid, uuid) from public, anon;
grant execute on function public.purge_withdrawn_student(uuid, uuid) to authenticated;

-- Safety net for the cron job: finishes purges the client could not complete.
-- Returns the number of students fully purged in this run.
create or replace function public.purge_withdrawn_students(
  p_budget_seconds integer default 40
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deadline timestamptz := clock_timestamp() + make_interval(secs => greatest(p_budget_seconds, 1));
  v_student_id uuid;
  v_done integer := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('purge_withdrawn_students')) then
    return 0;
  end if;

  for v_student_id in
    select s.id from public.students s
    where s.withdrawn_at is not null
    order by s.withdrawn_at
    limit 50
  loop
    loop
      exit when clock_timestamp() >= v_deadline;
      if public._purge_withdrawn_student_step(v_student_id, v_deadline) then
        v_done := v_done + 1;
        exit;
      end if;
    end loop;
    exit when clock_timestamp() >= v_deadline;
  end loop;

  return v_done;
end;
$$;

revoke all on function public.purge_withdrawn_students(integer) from public, anon, authenticated;

select cron.unschedule(j.jobid)
from cron.job j
where j.jobname = 'purge-withdrawn-students';

select cron.schedule(
  'purge-withdrawn-students',
  '* * * * *',
  $$
  set statement_timeout = '55s';
  select public.purge_withdrawn_students(40);
  $$
);

-- 3) kiosk search skips withdrawn students ----------------------------------

create or replace function public.kiosk_search_students(
  p_token_hash text,
  p_query text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_items jsonb;
begin
  select academy_id into v_academy
  from public.kiosk_devices
  where token_hash = p_token_hash and is_active and academy_id is not null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;
  if length(btrim(coalesce(p_query, ''))) < 1 then
    return jsonb_build_object('ok', false, 'error', 'query_required');
  end if;

  update public.kiosk_devices set last_seen_at = now() where token_hash = p_token_hash;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.name), '[]'::jsonb)
  into v_items
  from (
    select s.id as student_id, s.name, s.school, s.grade,
           coalesce(pin.pin_required, false) as pin_required,
           (pin.pin_hash is not null) as pin_set
    from public.students s
    left join public.m5_student_pins pin
      on pin.student_id = s.id and pin.academy_id = v_academy
    where s.academy_id = v_academy
      and s.withdrawn_at is null
      and (
        -- PostgreSQL does not decompose Hangul syllables into choseong.
        -- For a choseong query return a bounded academy roster and let the
        -- kiosk's Korean matcher apply the exact initial-consonant filter.
        btrim(p_query) ~ '^[ㄱ-ㅎ]+$'
        or s.name ilike '%' || btrim(p_query) || '%'
      )
    order by s.name
    limit case when btrim(p_query) ~ '^[ㄱ-ㅎ]+$' then 200 else 30 end
  ) q;
  return jsonb_build_object('ok', true, 'students', v_items);
end;
$$;
