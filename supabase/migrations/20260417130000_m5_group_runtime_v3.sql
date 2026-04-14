-- M5 group transition v3:
-- - Runtime state is tracked at group level.
-- - Child homework rows are committed only on completion.

create table if not exists public.homework_group_runtime (
  id bigserial primary key,
  academy_id uuid not null references public.academies(id) on delete cascade,
  group_id uuid not null references public.homework_groups(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  phase smallint not null default 1 check (phase between 1 and 4),
  accumulated_ms bigint not null default 0,
  run_start timestamptz null,
  first_started_at timestamptz null,
  check_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  constraint uq_homework_group_runtime unique (academy_id, group_id)
);

create index if not exists idx_homework_group_runtime_student
  on public.homework_group_runtime (academy_id, student_id, updated_at desc);

create or replace function public.m5_group_runtime_seed(
  p_academy_id uuid,
  p_group_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
begin
  select g.student_id
    into v_student_id
    from public.homework_groups g
   where g.id = p_group_id
     and g.academy_id = p_academy_id
     and g.status = 'active'
   limit 1;

  if v_student_id is null then
    return;
  end if;

  insert into public.homework_group_runtime (
    academy_id,
    group_id,
    student_id,
    phase,
    accumulated_ms,
    run_start,
    first_started_at,
    check_count
  )
  select
    p_academy_id,
    p_group_id,
    v_student_id,
    case
      when bool_or(h.run_start is not null) then 2::smallint
      when bool_or(coalesce(h.phase, 1) = 3) then 3::smallint
      when bool_or(coalesce(h.phase, 1) = 4) then 4::smallint
      else 1::smallint
    end as phase,
    coalesce(max(coalesce(h.accumulated_ms, 0)), 0)::bigint as accumulated_ms,
    (array_agg(h.run_start order by gi.item_order_index) filter (where h.run_start is not null))[1] as run_start,
    min(h.first_started_at) as first_started_at,
    coalesce(max(coalesce(h.check_count, 0)), 0)::integer as check_count
  from public.homework_group_items gi
  join public.homework_items h
    on h.id = gi.homework_item_id
   and h.academy_id = gi.academy_id
  where gi.academy_id = p_academy_id
    and gi.group_id = p_group_id
    and h.student_id = v_student_id
    and h.completed_at is null
    and coalesce(h.status, 0) <> 1
  on conflict (academy_id, group_id) do nothing;
end;
$$;

create or replace function public.m5_group_transition_state_v3(
  p_academy_id uuid,
  p_group_id uuid,
  p_from_phase smallint default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_from_phase smallint := p_from_phase;
  v_elapsed_ms bigint := 0;
  v_rows integer := 0;
  v_runtime public.homework_group_runtime%rowtype;
begin
  perform public.m5_group_runtime_seed(p_academy_id, p_group_id);

  select *
    into v_runtime
    from public.homework_group_runtime r
   where r.academy_id = p_academy_id
     and r.group_id = p_group_id
   for update;

  if not found then
    return 0;
  end if;

  if v_from_phase is null then
    v_from_phase := coalesce(v_runtime.phase, 1);
  end if;

  if v_from_phase = 1 then
    update public.homework_group_runtime r
       set phase = 2,
           run_start = coalesce(r.run_start, v_now),
           first_started_at = coalesce(r.first_started_at, v_now),
           updated_at = v_now,
           version = coalesce(r.version, 1) + 1
     where r.academy_id = p_academy_id
       and r.group_id = p_group_id
       and (r.phase <> 2 or r.run_start is null);
    get diagnostics v_rows = row_count;
  elsif v_from_phase = 2 then
    v_elapsed_ms := case
      when v_runtime.run_start is not null
        then greatest(0, floor(extract(epoch from (v_now - v_runtime.run_start)) * 1000)::bigint)
      else 0
    end;

    update public.homework_group_runtime r
       set phase = 3,
           accumulated_ms = coalesce(r.accumulated_ms, 0) + v_elapsed_ms,
           run_start = null,
           check_count = coalesce(r.check_count, 0) + 1,
           updated_at = v_now,
           version = coalesce(r.version, 1) + 1
     where r.academy_id = p_academy_id
       and r.group_id = p_group_id
       and (r.phase <> 3 or r.run_start is not null);
    get diagnostics v_rows = row_count;
  elsif v_from_phase = 4 then
    v_elapsed_ms := case
      when v_runtime.run_start is not null
        then greatest(0, floor(extract(epoch from (v_now - v_runtime.run_start)) * 1000)::bigint)
      else 0
    end;

    update public.homework_group_runtime r
       set phase = 1,
           accumulated_ms = coalesce(r.accumulated_ms, 0) + v_elapsed_ms,
           run_start = null,
           updated_at = v_now,
           version = coalesce(r.version, 1) + 1
     where r.academy_id = p_academy_id
       and r.group_id = p_group_id
       and (r.phase <> 1 or r.run_start is not null);
    get diagnostics v_rows = row_count;
  end if;

  if v_rows > 0 then
    update public.homework_groups g
       set updated_at = v_now,
           version = coalesce(g.version, 1) + 1
     where g.id = p_group_id
       and g.academy_id = p_academy_id
       and g.status = 'active';
  end if;

  return v_rows;
end;
$$;

create or replace function public.m5_group_commit_children_v3(
  p_academy_id uuid,
  p_group_id uuid
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_rows integer := 0;
  v_runtime public.homework_group_runtime%rowtype;
  v_elapsed_ms bigint := 0;
begin
  perform public.m5_group_runtime_seed(p_academy_id, p_group_id);

  select *
    into v_runtime
    from public.homework_group_runtime r
   where r.academy_id = p_academy_id
     and r.group_id = p_group_id
   for update;

  if not found then
    return 0;
  end if;

  v_elapsed_ms := case
    when v_runtime.run_start is not null
      then greatest(0, floor(extract(epoch from (v_now - v_runtime.run_start)) * 1000)::bigint)
    else 0
  end;

  update public.homework_group_runtime r
     set phase = 3,
         accumulated_ms = coalesce(r.accumulated_ms, 0) + v_elapsed_ms,
         run_start = null,
         check_count = coalesce(r.check_count, 0) + 1,
         updated_at = v_now,
         version = coalesce(r.version, 1) + 1
   where r.academy_id = p_academy_id
     and r.group_id = p_group_id;

  with updated as (
    update public.homework_items h
       set run_start = null,
           phase = 3,
           submitted_at = coalesce(h.submitted_at, v_now),
           updated_at = v_now,
           version = coalesce(h.version, 1) + 1
      where h.academy_id = p_academy_id
        and h.student_id = v_runtime.student_id
        and h.completed_at is null
        and coalesce(h.status, 0) <> 1
        and exists (
          select 1
            from public.homework_group_items gi
           where gi.academy_id = p_academy_id
             and gi.group_id = p_group_id
             and gi.homework_item_id = h.id
        )
        and (h.phase <> 3 or h.run_start is not null or h.submitted_at is null)
    returning h.id
  )
  insert into public.homework_item_phase_events(academy_id, item_id, phase, actor_user_id, note)
  select p_academy_id, u.id, 3::smallint, auth.uid(), 'group_runtime_commit'
    from updated u;

  get diagnostics v_rows = row_count;

  update public.homework_groups g
     set updated_at = v_now,
         version = coalesce(g.version, 1) + 1
   where g.id = p_group_id
     and g.academy_id = p_academy_id
     and g.status = 'active';

  return v_rows;
end;
$$;

create or replace function public.m5_group_transition_command(
  p_academy_id uuid,
  p_group_id uuid,
  p_from_phase smallint default null,
  p_request_id text default null,
  p_device_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id text := nullif(trim(coalesce(p_request_id, '')), '');
  v_device_id text := nullif(trim(coalesce(p_device_id, '')), '');
  v_group_student uuid;
  v_bound_student uuid;
  v_changed integer := 0;
  v_inserted integer := 0;
  v_result jsonb;
  v_existing jsonb;
  v_mode text := case when p_from_phase = 99 then 'commit' else 'state' end;
begin
  if p_academy_id is null then
    return jsonb_build_object('ok', false, 'error', 'academy_id_required');
  end if;
  if p_group_id is null then
    return jsonb_build_object('ok', false, 'error', 'group_id_required');
  end if;
  if v_request_id is null then
    return jsonb_build_object('ok', false, 'error', 'request_id_required');
  end if;
  if v_device_id is null then
    return jsonb_build_object('ok', false, 'error', 'device_id_required');
  end if;

  select g.student_id
    into v_group_student
    from public.homework_groups g
   where g.id = p_group_id
     and g.academy_id = p_academy_id
   limit 1;

  if v_group_student is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'group_not_found',
      'academy_id', p_academy_id,
      'group_id', p_group_id,
      'request_id', v_request_id,
      'device_id', v_device_id
    );
  end if;

  select b.student_id
    into v_bound_student
    from public.m5_device_bindings b
   where b.academy_id = p_academy_id
     and b.device_id = v_device_id
     and b.active = true
   limit 1;

  if v_bound_student is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'device_not_bound',
      'academy_id', p_academy_id,
      'group_id', p_group_id,
      'student_id', v_group_student,
      'request_id', v_request_id,
      'device_id', v_device_id
    );
  end if;

  if v_bound_student <> v_group_student then
    return jsonb_build_object(
      'ok', false,
      'error', 'binding_mismatch',
      'academy_id', p_academy_id,
      'group_id', p_group_id,
      'student_id', v_group_student,
      'bound_student_id', v_bound_student,
      'request_id', v_request_id,
      'device_id', v_device_id
    );
  end if;

  insert into public.homework_group_transition_requests (
    academy_id,
    request_id,
    group_id,
    student_id,
    from_phase,
    device_id
  ) values (
    p_academy_id,
    v_request_id,
    p_group_id,
    v_group_student,
    p_from_phase,
    v_device_id
  )
  on conflict (academy_id, request_id) do nothing;

  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    select r.result_json
      into v_existing
      from public.homework_group_transition_requests r
     where r.academy_id = p_academy_id
       and r.request_id = v_request_id
     limit 1;

    if v_existing is null then
      return jsonb_build_object(
        'ok', true,
        'dedup', true,
        'mode', v_mode,
        'changed', 0,
        'academy_id', p_academy_id,
        'group_id', p_group_id,
        'student_id', v_group_student,
        'request_id', v_request_id,
        'device_id', v_device_id
      );
    end if;

    return v_existing || jsonb_build_object('dedup', true);
  end if;

  if p_from_phase = 99 then
    v_changed := coalesce(public.m5_group_commit_children_v3(p_academy_id, p_group_id), 0);
  else
    v_changed := coalesce(public.m5_group_transition_state_v3(p_academy_id, p_group_id, p_from_phase), 0);
  end if;

  v_result := jsonb_build_object(
    'ok', true,
    'dedup', false,
    'mode', v_mode,
    'changed', v_changed,
    'academy_id', p_academy_id,
    'group_id', p_group_id,
    'student_id', v_group_student,
    'from_phase', p_from_phase,
    'request_id', v_request_id,
    'device_id', v_device_id
  );

  update public.homework_group_transition_requests r
     set changed_count = v_changed,
         result_json = v_result,
         updated_at = now()
   where r.academy_id = p_academy_id
     and r.request_id = v_request_id;

  return v_result;
exception when others then
  v_result := jsonb_build_object(
    'ok', false,
    'mode', v_mode,
    'error', sqlerrm,
    'academy_id', p_academy_id,
    'group_id', p_group_id,
    'student_id', v_group_student,
    'request_id', v_request_id,
    'device_id', v_device_id
  );

  if v_request_id is not null then
    update public.homework_group_transition_requests r
       set result_json = v_result,
           updated_at = now()
     where r.academy_id = p_academy_id
       and r.request_id = v_request_id;
  end if;

  return v_result;
end;
$$;

revoke all on function public.m5_group_runtime_seed(uuid, uuid) from public;
revoke all on function public.m5_group_transition_state_v3(uuid, uuid, smallint) from public;
revoke all on function public.m5_group_commit_children_v3(uuid, uuid) from public;
revoke all on function public.m5_group_transition_command(uuid, uuid, smallint, text, text) from public;

grant execute on function public.m5_group_transition_state_v3(uuid, uuid, smallint) to service_role;
grant execute on function public.m5_group_commit_children_v3(uuid, uuid) to service_role;
grant execute on function public.m5_group_transition_command(uuid, uuid, smallint, text, text) to service_role;

drop function if exists public.m5_list_homework_groups(uuid, uuid);

create function public.m5_list_homework_groups(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
  group_id uuid,
  group_title text,
  order_index integer,
  phase smallint,
  accumulated bigint,
  cycle_elapsed bigint,
  check_count integer,
  total_count integer,
  color bigint,
  page_summary text,
  run_start timestamptz,
  first_started_at timestamptz,
  content text,
  book_id text,
  grade_label text,
  "type" text,
  time_limit_minutes integer,
  m5_wait_title text,
  children jsonb
) as $$
begin
  return query
  with active_items as (
    select
      gi.group_id,
      gi.item_order_index,
      h.id as item_id,
      h.title,
      h.page,
      h."count",
      h.memo,
      coalesce(h.check_count, 0)::integer as check_count,
      h.color::bigint as color,
      coalesce(h.phase, 1)::smallint as phase,
      (coalesce(h.accumulated_ms, 0) / 1000)::bigint as accumulated,
      (
        (
          case
            when coalesce(h.cycle_base_accumulated_ms, 0) <= 0
                 and coalesce(h.phase, 1) = 1
                 and coalesce(h.accumulated_ms, 0) > 0
              then coalesce(h.accumulated_ms, 0)
            else coalesce(h.cycle_base_accumulated_ms, 0)
          end
        ) / 1000
      )::bigint as cycle_base_sec,
      greatest(
        0::bigint,
        (
          (
            coalesce(h.accumulated_ms, 0)
            -
            case
              when coalesce(h.cycle_base_accumulated_ms, 0) <= 0
                   and coalesce(h.phase, 1) = 1
                   and coalesce(h.accumulated_ms, 0) > 0
                then coalesce(h.accumulated_ms, 0)
              else coalesce(h.cycle_base_accumulated_ms, 0)
            end
          ) / 1000
        )::bigint
      ) as cycle_elapsed_sec,
      h.run_start,
      h.first_started_at,
      h.content,
      h.book_id::text as book_id,
      h.grade_label,
      h."type",
      coalesce(h.time_limit_minutes, 0)::integer as time_limit_minutes,
      h.submitted_at,
      h.confirmed_at,
      h.waiting_at,
      nullif(
        trim(
          concat_ws(
            ' ',
            nullif(
              regexp_replace(
                trim(
                  coalesce(
                    doc.exam_year::text,
                    doc.meta #>> '{source_classification,naesin,year}',
                    ''
                  )
                ),
                '[^0-9]',
                '',
                'g'
              ),
              ''
            ),
            nullif(
              trim(regexp_replace(trim(coalesce(doc.school_name, '')), '학교$', '')),
              ''
            ),
            nullif(
              trim(
                coalesce(
                  nullif(trim(doc.grade_label), ''),
                  nullif(trim(h.grade_label), '')
                )
              ),
              ''
            ),
            nullif(trim(doc.semester_label), ''),
            nullif(trim(doc.exam_term_label), ''),
            nullif(
              coalesce(
                nullif(trim(rf.name), ''),
                nullif(trim(doc.material_name), ''),
                nullif(trim(h.title), '')
              ),
              ''
            )
          )
        ),
        ''
      ) as m5_wait_title
    from public.homework_group_items gi
    join public.homework_items h on h.id = gi.homework_item_id
    left join public.pb_export_presets pr
      on pr.id = h.pb_preset_id
     and pr.academy_id = h.academy_id
    left join public.pb_documents doc
      on doc.academy_id = h.academy_id
     and doc.id = coalesce(pr.source_document_id, pr.document_id)
    left join public.resource_files rf
      on rf.id = h.book_id
     and rf.academy_id = h.academy_id
    where gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and h.academy_id = p_academy_id
      and h.student_id = p_student_id
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and coalesce(h.phase, 1) between 1 and 4
      and not exists (
        select 1
        from public.homework_assignments a
        where a.homework_item_id = h.id
          and a.academy_id = p_academy_id
          and a.student_id = p_student_id
          and a.status = 'assigned'
      )
  ),
  group_summary as (
    select
      g.id as group_id,
      g.title as group_title,
      g.order_index,
      case
        when bool_or(ai.run_start is not null) then 2::smallint
        when bool_or(ai.phase = 3) then 3::smallint
        when bool_or(ai.phase = 4) then 4::smallint
        else greatest(max(ai.phase), 1)::smallint
      end as phase,
      (sum(ai.cycle_base_sec) + coalesce(max(ai.cycle_elapsed_sec), 0))::bigint as accumulated,
      coalesce(max(ai.cycle_elapsed_sec), 0)::bigint as cycle_elapsed,
      max(ai.check_count)::integer as check_count,
      sum(coalesce(ai."count", 0))::integer as total_count,
      (array_agg(ai.color order by ai.item_order_index))[1] as color,
      string_agg(
        case when ai.page is not null and ai.page <> '' then ai.page else null end,
        ', ' order by ai.item_order_index
      ) as page_summary,
      (array_agg(ai.run_start order by ai.item_order_index) filter (where ai.run_start is not null))[1] as run_start,
      min(ai.first_started_at) as first_started_at,
      (array_agg(ai.content order by ai.item_order_index))[1] as content,
      (array_agg(ai.book_id order by ai.item_order_index))[1] as book_id,
      (array_agg(ai.grade_label order by ai.item_order_index))[1] as grade_label,
      (array_agg(ai."type" order by ai.item_order_index))[1] as "type",
      coalesce((array_agg(ai.time_limit_minutes order by ai.item_order_index))[1], 0)::integer as time_limit_minutes,
      (array_agg(ai.m5_wait_title order by ai.item_order_index))[1] as m5_wait_title,
      jsonb_agg(
        jsonb_build_object(
          'item_id', ai.item_id,
          'title', ai.title,
          'page', ai.page,
          'count', ai."count",
          'memo', ai.memo,
          'check_count', ai.check_count,
          'phase', ai.phase,
          'accumulated', ai.accumulated,
          'run_start', ai.run_start
        ) order by ai.item_order_index
      ) as children
    from public.homework_groups g
    join active_items ai on ai.group_id = g.id
    where g.academy_id = p_academy_id
      and g.student_id = p_student_id
      and g.status = 'active'
    group by g.id, g.title, g.order_index
  )
  select
    gs.group_id,
    gs.group_title,
    gs.order_index,
    coalesce(gr.phase, gs.phase)::smallint as phase,
    case
      when gr.phase is null then gs.accumulated
      else (
        coalesce(gr.accumulated_ms, 0)
        + case
            when gr.phase = 2 and gr.run_start is not null
              then greatest(0, floor(extract(epoch from (now() - gr.run_start)) * 1000)::bigint)
            else 0
          end
      ) / 1000
    end::bigint as accumulated,
    case
      when gr.phase is null then gs.cycle_elapsed
      when gr.phase = 2 and gr.run_start is not null
        then greatest(0, floor(extract(epoch from (now() - gr.run_start)))::bigint)
      else 0::bigint
    end as cycle_elapsed,
    coalesce(gr.check_count, gs.check_count)::integer as check_count,
    gs.total_count,
    gs.color,
    gs.page_summary,
    case
      when gr.phase = 2 then gr.run_start
      when gr.phase is null then gs.run_start
      else null
    end as run_start,
    coalesce(gr.first_started_at, gs.first_started_at) as first_started_at,
    gs.content,
    gs.book_id,
    gs.grade_label,
    gs."type",
    gs.time_limit_minutes,
    gs.m5_wait_title,
    case
      when gr.phase is null or gs.children is null then gs.children
      else (
        select jsonb_agg(
          jsonb_set(
            jsonb_set(
              child_elem,
              '{phase}',
              to_jsonb(gr.phase::integer),
              true
            ),
            '{run_start}',
            case
              when gr.phase = 2 and gr.run_start is not null
                then to_jsonb(gr.run_start)
              else 'null'::jsonb
            end,
            true
          )
        )
        from jsonb_array_elements(gs.children) as child_elem
      )
    end as children
  from group_summary gs
  left join public.homework_group_runtime gr
    on gr.academy_id = p_academy_id
   and gr.group_id = gs.group_id
   and gr.student_id = p_student_id
  order by gs.order_index asc, gs.group_id asc;
end;
$$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_list_homework_groups(uuid, uuid) to anon, authenticated;
