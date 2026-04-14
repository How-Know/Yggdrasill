-- Device group_transition v2 idempotency ledger + RPC wrapper.
-- Keeps existing homework_group_bulk_transition signature untouched.

create table if not exists public.homework_group_transition_requests (
  id bigserial primary key,
  academy_id uuid not null references public.academies(id) on delete cascade,
  request_id text not null,
  group_id uuid not null references public.homework_groups(id) on delete cascade,
  student_id uuid null references public.students(id) on delete set null,
  from_phase smallint null,
  device_id text null,
  changed_count integer not null default 0,
  result_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_hw_group_transition_request unique (academy_id, request_id)
);

create index if not exists idx_hw_group_transition_requests_created_at
  on public.homework_group_transition_requests (academy_id, created_at desc);

create index if not exists idx_hw_group_transition_requests_group
  on public.homework_group_transition_requests (academy_id, group_id, created_at desc);

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

  v_changed := coalesce(
    public.homework_group_bulk_transition(p_group_id, p_academy_id, p_from_phase),
    0
  );

  v_result := jsonb_build_object(
    'ok', true,
    'dedup', false,
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

revoke all on function public.m5_group_transition_command(uuid, uuid, smallint, text, text) from public;
grant execute on function public.m5_group_transition_command(uuid, uuid, smallint, text, text) to service_role;
