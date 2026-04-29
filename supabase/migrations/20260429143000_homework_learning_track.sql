-- Homework learning track: CL/PL/FL/EL and assignment codes prefixed by track.

alter table public.homework_items
  add column if not exists learning_track_code text;

alter table public.homework_groups
  add column if not exists learning_track_code text;

alter table public.homework_assignments
  add column if not exists learning_track_code_snapshot text;

create or replace function public.homework_normalize_learning_track_code(
  p_code text
) returns text
language sql
immutable
as $$
  select case upper(trim(coalesce(p_code, '')))
    when 'CL' then 'CL'
    when 'PL' then 'PL'
    when 'FL' then 'FL'
    when 'EL' then 'EL'
    else 'EL'
  end
$$;

create or replace function public.homework_issue_assignment_code(
  p_academy_id uuid,
  p_learning_track_code text default 'EL'
) returns text
language plpgsql
volatile
security invoker
set search_path = public
as $$
declare
  v_letters constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_track text := public.homework_normalize_learning_track_code(p_learning_track_code);
  v_code text;
  v_try int := 0;
begin
  if p_academy_id is null then
    raise exception 'homework_issue_assignment_code: academy_id required';
  end if;

  loop
    v_try := v_try + 1;
    v_code :=
      v_track ||
      substr(v_letters, (floor(random() * length(v_letters))::int + 1), 1) ||
      substr(v_letters, (floor(random() * length(v_letters))::int + 1), 1) ||
      lpad((floor(random() * 10000))::int::text, 4, '0');

    if not exists (
      select 1
      from public.homework_items hi
      where hi.academy_id = p_academy_id
        and hi.assignment_code = v_code
    ) then
      return v_code;
    end if;

    if v_try >= 256 then
      raise exception 'homework_issue_assignment_code: failed after % attempts', v_try;
    end if;
  end loop;
end;
$$;

create or replace function public.homework_issue_assignment_code(
  p_academy_id uuid
) returns text
language sql
volatile
security invoker
set search_path = public
as $$
  select public.homework_issue_assignment_code(p_academy_id, 'EL')
$$;

create or replace function public.homework_items_assign_code_trigger()
returns trigger
language plpgsql
volatile
security invoker
set search_path = public
as $$
begin
  if new.assignment_code is not null then
    new.assignment_code := upper(trim(new.assignment_code));
    if new.assignment_code = '' then
      new.assignment_code := null;
    end if;
  end if;

  new.learning_track_code := public.homework_normalize_learning_track_code(
    coalesce(
      new.learning_track_code,
      case
        when new.assignment_code ~ '^(CL|PL|FL|EL)[A-Z]{2}[0-9]{4}$'
          then substring(new.assignment_code from 1 for 2)
        else null
      end
    )
  );

  if new.academy_id is not null and (
    new.assignment_code is null
    or new.assignment_code !~ '^(CL|PL|FL|EL)[A-Z]{2}[0-9]{4}$'
    or substring(new.assignment_code from 1 for 2) <> new.learning_track_code
  ) then
    new.assignment_code :=
      public.homework_issue_assignment_code(new.academy_id, new.learning_track_code);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_homework_items_assign_code on public.homework_items;

create trigger trg_homework_items_assign_code
before insert or update of assignment_code, learning_track_code
on public.homework_items
for each row
execute function public.homework_items_assign_code_trigger();

update public.homework_items
set learning_track_code = public.homework_normalize_learning_track_code(learning_track_code)
where learning_track_code is null
   or learning_track_code not in ('CL', 'PL', 'FL', 'EL');

update public.homework_groups
set learning_track_code = public.homework_normalize_learning_track_code(learning_track_code)
where learning_track_code is null
   or learning_track_code not in ('CL', 'PL', 'FL', 'EL');

update public.homework_assignments
set learning_track_code_snapshot =
  public.homework_normalize_learning_track_code(learning_track_code_snapshot)
where learning_track_code_snapshot is not null
  and learning_track_code_snapshot not in ('CL', 'PL', 'FL', 'EL');

do $$
declare
  v_row record;
  v_code text;
begin
  for v_row in
    select id, academy_id, learning_track_code
    from public.homework_items
    where assignment_code is null
       or assignment_code !~ '^(CL|PL|FL|EL)[A-Z]{2}[0-9]{4}$'
       or substring(assignment_code from 1 for 2) <>
          public.homework_normalize_learning_track_code(learning_track_code)
    order by created_at nulls first, id
  loop
    loop
      v_code := public.homework_issue_assignment_code(
        v_row.academy_id,
        v_row.learning_track_code
      );
      begin
        update public.homework_items
        set assignment_code = v_code,
            learning_track_code =
              public.homework_normalize_learning_track_code(v_row.learning_track_code)
        where id = v_row.id;
        exit;
      exception
        when unique_violation then
          null;
      end;
    end loop;
  end loop;
end
$$;

alter table public.homework_items
  drop constraint if exists homework_items_assignment_code_format_chk;

alter table public.homework_items
  add constraint homework_items_assignment_code_format_chk
  check (
    assignment_code is null
    or assignment_code ~ '^(CL|PL|FL|EL)[A-Z]{2}[0-9]{4}$'
  );

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'homework_items_learning_track_code_chk'
  ) then
    alter table public.homework_items
      add constraint homework_items_learning_track_code_chk
      check (learning_track_code in ('CL', 'PL', 'FL', 'EL'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'homework_groups_learning_track_code_chk'
  ) then
    alter table public.homework_groups
      add constraint homework_groups_learning_track_code_chk
      check (learning_track_code in ('CL', 'PL', 'FL', 'EL'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'homework_assignments_learning_track_code_snapshot_chk'
  ) then
    alter table public.homework_assignments
      add constraint homework_assignments_learning_track_code_snapshot_chk
      check (
        learning_track_code_snapshot is null
        or learning_track_code_snapshot in ('CL', 'PL', 'FL', 'EL')
      );
  end if;
end
$$;

create index if not exists homework_items_learning_track_code_idx
  on public.homework_items (academy_id, learning_track_code);

create index if not exists homework_groups_learning_track_code_idx
  on public.homework_groups (academy_id, learning_track_code);

create or replace function public.homework_create_reserved_homework_bundle(
  p_academy_id uuid,
  p_student_id uuid,
  p_group jsonb,
  p_items jsonb
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = public
as $$
declare
  elem jsonb;
  v_item_id uuid;
  v_group_id uuid;
  v_flow_text text;
  v_next_assign_order int;
  v_idx int := 0;
  v_i int;
  v_len int;
  v_split int;
  v_assigned_id uuid;
  v_has_group boolean;
  v_g_title text;
  v_g_order int;
  v_group_track text;
  v_item_track text;
  v_assignment_code text;
  v_note text := '__reserved_homework__';
begin
  if p_academy_id is null or p_student_id is null then
    raise exception 'homework_create_reserved_homework_bundle: academy_id and student_id required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 then
    raise exception 'homework_create_reserved_homework_bundle: p_items must be a non-empty array';
  end if;

  v_has_group :=
    p_group is not null
    and jsonb_typeof(p_group) = 'object'
    and nullif(trim(p_group->>'id'), '') is not null;

  if v_has_group then
    v_group_track := public.homework_normalize_learning_track_code(
      coalesce(p_group->>'learning_track_code', p_group->>'learningTrackCode')
    );
  end if;

  v_len := jsonb_array_length(p_items);
  for v_i in 0..v_len - 1
  loop
    elem := p_items->v_i;
    v_item_track := public.homework_normalize_learning_track_code(
      coalesce(
        elem->>'learning_track_code',
        elem->>'learningTrackCode',
        v_group_track
      )
    );
    if v_has_group then
      if v_group_track is null then
        v_group_track := v_item_track;
      elsif v_group_track <> v_item_track then
        raise exception 'homework_create_reserved_homework_bundle: mixed learning_track_code in group';
      end if;
    end if;
  end loop;

  if v_group_track is null then
    v_group_track := 'EL';
  end if;

  if v_has_group then
    v_group_id := (trim(p_group->>'id'))::uuid;
    v_g_title := coalesce(nullif(trim(p_group->>'title'), ''), '그룹 과제');
    v_g_order := coalesce((p_group->>'order_index')::int, 0);
    v_flow_text := nullif(trim(p_group->>'flow_id'), '');
    insert into public.homework_groups (
      id,
      academy_id,
      student_id,
      title,
      flow_id,
      learning_track_code,
      order_index,
      status,
      created_at,
      updated_at,
      version
    )
    values (
      v_group_id,
      p_academy_id,
      p_student_id,
      v_g_title,
      case
        when v_flow_text is null then null
        else v_flow_text::uuid
      end,
      v_group_track,
      v_g_order,
      'active',
      now(),
      now(),
      1
    );
  end if;

  select coalesce(max(order_index), -1) + 1
    into v_next_assign_order
    from public.homework_assignments
   where academy_id = p_academy_id
     and student_id = p_student_id
     and status = 'assigned'
     and due_date is null;

  for v_i in 0..v_len - 1
  loop
    elem := p_items->v_i;
    v_idx := v_idx + 1;
    v_item_id := (trim(elem->>'id'))::uuid;
    v_item_track := public.homework_normalize_learning_track_code(
      coalesce(
        elem->>'learning_track_code',
        elem->>'learningTrackCode',
        v_group_track
      )
    );
    v_assignment_code :=
      upper(trim(coalesce(elem->>'assignment_code', elem->>'assignmentCode', '')));
    v_split := greatest(
      1,
      least(
        4,
        coalesce(
          nullif((elem->>'split_parts')::int, 0),
          nullif((elem->>'default_split_parts')::int, 0),
          1
        )
      )
    );

    insert into public.homework_items (
      id,
      academy_id,
      student_id,
      title,
      body,
      color,
      flow_id,
      test_origin_flow_id,
      learning_track_code,
      assignment_code,
      type,
      page,
      count,
      time_limit_minutes,
      pb_preset_id,
      memo,
      content,
      book_id,
      grade_label,
      source_unit_level,
      source_unit_path,
      default_split_parts,
      order_index,
      check_count,
      status,
      phase,
      accumulated_ms,
      run_start,
      completed_at,
      first_started_at,
      submitted_at,
      confirmed_at,
      waiting_at,
      version
    )
    values (
      v_item_id,
      p_academy_id,
      p_student_id,
      coalesce(nullif(trim(elem->>'title'), ''), '과제'),
      coalesce(
        nullif(trim(elem->>'body'), ''),
        coalesce(nullif(trim(elem->>'title'), ''), '과제')
      ),
      coalesce((elem->>'color')::bigint, 4280391410),
      case
        when nullif(trim(elem->>'flow_id'), '') is null then null
        else trim(elem->>'flow_id')::uuid
      end,
      case
        when nullif(
            trim(
              coalesce(elem->>'test_origin_flow_id', elem->>'testOriginFlowId', '')
            ),
            ''
          ) is null
        then null
        else trim(
            coalesce(elem->>'test_origin_flow_id', elem->>'testOriginFlowId')
          )::uuid
      end,
      v_item_track,
      case
        when v_assignment_code ~ '^(CL|PL|FL|EL)[A-Z]{2}[0-9]{4}$'
          and substring(v_assignment_code from 1 for 2) = v_item_track
        then v_assignment_code
        else public.homework_issue_assignment_code(p_academy_id, v_item_track)
      end,
      nullif(elem->>'type', ''),
      nullif(elem->>'page', ''),
      (elem->>'count')::int,
      case
        when (elem ? 'time_limit_minutes')
          and coalesce((elem->>'time_limit_minutes')::int, 0) > 0
        then (elem->>'time_limit_minutes')::int
        else null
      end,
      case
        when nullif(
            trim(coalesce(elem->>'pb_preset_id', elem->>'pbPresetId', '')),
            ''
          ) is null
        then null
        else trim(coalesce(elem->>'pb_preset_id', elem->>'pbPresetId'))::uuid
      end,
      nullif(elem->>'memo', ''),
      nullif(elem->>'content', ''),
      case
        when nullif(trim(coalesce(elem->>'book_id', '')), '') is null then null
        else trim(elem->>'book_id')::uuid
      end,
      nullif(elem->>'grade_label', ''),
      nullif(elem->>'source_unit_level', ''),
      nullif(elem->>'source_unit_path', ''),
      greatest(1, least(4, coalesce((elem->>'default_split_parts')::int, 1))),
      coalesce((elem->>'order_index')::int, 0),
      coalesce((elem->>'check_count')::int, 0),
      coalesce((elem->>'status')::int, 0),
      coalesce((elem->>'phase')::int, 1),
      coalesce((elem->>'accumulated_ms')::bigint, 0),
      nullif(elem->>'run_start', '')::timestamptz,
      nullif(elem->>'completed_at', '')::timestamptz,
      nullif(elem->>'first_started_at', '')::timestamptz,
      nullif(elem->>'submitted_at', '')::timestamptz,
      nullif(elem->>'confirmed_at', '')::timestamptz,
      coalesce(nullif(elem->>'waiting_at', '')::timestamptz, now()),
      1
    );

    if v_has_group then
      insert into public.homework_group_items (
        academy_id,
        group_id,
        student_id,
        homework_item_id,
        item_order_index,
        created_at,
        updated_at,
        version
      )
      values (
        p_academy_id,
        v_group_id,
        p_student_id,
        v_item_id,
        coalesce((elem->>'item_order_index')::int, v_idx - 1),
        now(),
        now(),
        1
      );
    end if;

    v_assigned_id := gen_random_uuid();
    insert into public.homework_assignments (
      id,
      academy_id,
      student_id,
      homework_item_id,
      assigned_at,
      due_date,
      order_index,
      status,
      note,
      progress,
      repeat_index,
      split_parts,
      split_round,
      group_id,
      group_title_snapshot,
      learning_track_code_snapshot,
      version,
      created_at,
      updated_at
    )
    values (
      v_assigned_id,
      p_academy_id,
      p_student_id,
      v_item_id,
      now(),
      null,
      v_next_assign_order,
      'assigned',
      v_note,
      0,
      1,
      v_split,
      1,
      case when v_has_group then v_group_id else null end,
      case
        when v_has_group then v_g_title
        else coalesce(nullif(trim(elem->>'title'), ''), '과제')
      end,
      v_item_track,
      1,
      now(),
      now()
    );

    v_next_assign_order := v_next_assign_order + 1;
  end loop;

  return jsonb_build_object('ok', true, 'group_id', to_jsonb(v_group_id));
end;
$$;
