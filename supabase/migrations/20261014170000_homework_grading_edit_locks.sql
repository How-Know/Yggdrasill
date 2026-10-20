-- A structured homework grading sheet is edited by one staff session at a
-- time. Other staff may still open it read-only. Leases avoid permanent
-- locks when an app or PC disappears.

create table if not exists public.homework_grading_edit_locks (
  academy_id uuid not null references public.academies(id) on delete cascade,
  target_key text not null,
  student_id uuid not null references public.students(id) on delete cascade,
  group_id uuid references public.homework_groups(id) on delete cascade,
  homework_item_ids uuid[] not null default array[]::uuid[],
  owner_user_id uuid not null,
  owner_name text not null,
  session_token uuid not null,
  acquired_at timestamptz not null default now(),
  heartbeat_at timestamptz not null default now(),
  expires_at timestamptz not null,
  primary key (academy_id, target_key)
);

create index if not exists idx_homework_grading_edit_locks_expires
  on public.homework_grading_edit_locks(expires_at);

alter table public.homework_grading_edit_locks enable row level security;

create or replace function public.homework_grading_lock_acquire_v1(
  p_academy_id uuid,
  p_student_id uuid,
  p_group_id uuid,
  p_homework_item_ids uuid[],
  p_session_token uuid,
  p_lease_seconds integer default 180
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target_key text;
  v_owner_name text;
  v_lease_seconds integer := greatest(60, least(600, coalesce(p_lease_seconds, 180)));
  v_lock public.homework_grading_edit_locks%rowtype;
begin
  if auth.uid() is null
      or p_academy_id is null
      or p_student_id is null
      or p_group_id is null
      or p_session_token is null
      or cardinality(coalesce(p_homework_item_ids, array[]::uuid[])) = 0 then
    raise exception 'HOMEWORK_GRADING_LOCK_ARGS_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_GRADING_LOCK_FORBIDDEN';
  end if;

  if not exists (
    select 1
    from public.homework_groups g
    where g.id = p_group_id
      and g.academy_id = p_academy_id
      and g.student_id = p_student_id
  ) then
    raise exception 'HOMEWORK_GRADING_LOCK_GROUP_NOT_FOUND';
  end if;

  if exists (
    select 1
    from unnest(p_homework_item_ids) requested(item_id)
    where not exists (
      select 1
      from public.homework_group_items gi
      where gi.academy_id = p_academy_id
        and gi.student_id = p_student_id
        and gi.group_id = p_group_id
        and gi.homework_item_id = requested.item_id
    )
  ) then
    raise exception 'HOMEWORK_GRADING_LOCK_ITEM_NOT_IN_GROUP';
  end if;

  v_target_key := 'group:' || p_group_id::text;
  select coalesce(
    (
      select nullif(trim(t.name), '')
      from public.teachers t
      where t.academy_id = p_academy_id
        and t.user_id = auth.uid()
      order by t.updated_at desc, t.id
      limit 1
    ),
    nullif(split_part(coalesce(auth.jwt()->>'email', ''), '@', 1), ''),
    '다른 선생님'
  ) into v_owner_name;

  insert into public.homework_grading_edit_locks (
    academy_id,
    target_key,
    student_id,
    group_id,
    homework_item_ids,
    owner_user_id,
    owner_name,
    session_token,
    acquired_at,
    heartbeat_at,
    expires_at
  ) values (
    p_academy_id,
    v_target_key,
    p_student_id,
    p_group_id,
    p_homework_item_ids,
    auth.uid(),
    v_owner_name,
    p_session_token,
    now(),
    now(),
    now() + make_interval(secs => v_lease_seconds)
  )
  on conflict (academy_id, target_key) do update
  set student_id = excluded.student_id,
      group_id = excluded.group_id,
      homework_item_ids = excluded.homework_item_ids,
      owner_user_id = excluded.owner_user_id,
      owner_name = excluded.owner_name,
      session_token = excluded.session_token,
      acquired_at = case
        when public.homework_grading_edit_locks.session_token = excluded.session_token
          then public.homework_grading_edit_locks.acquired_at
        else now()
      end,
      heartbeat_at = now(),
      expires_at = excluded.expires_at
  where public.homework_grading_edit_locks.expires_at <= now()
     or public.homework_grading_edit_locks.session_token = excluded.session_token;

  select *
  into v_lock
  from public.homework_grading_edit_locks l
  where l.academy_id = p_academy_id
    and l.target_key = v_target_key;

  return jsonb_build_object(
    'acquired', v_lock.session_token = p_session_token,
    'target_key', v_target_key,
    'owner_name', v_lock.owner_name,
    'expires_at', v_lock.expires_at
  );
end;
$$;

create or replace function public.homework_grading_lock_heartbeat_v1(
  p_academy_id uuid,
  p_target_key text,
  p_session_token uuid,
  p_lease_seconds integer default 180
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lease_seconds integer := greatest(60, least(600, coalesce(p_lease_seconds, 180)));
begin
  update public.homework_grading_edit_locks l
  set heartbeat_at = now(),
      expires_at = now() + make_interval(secs => v_lease_seconds)
  where l.academy_id = p_academy_id
    and l.target_key = p_target_key
    and l.owner_user_id = auth.uid()
    and l.session_token = p_session_token
    and l.expires_at > now();
  return found;
end;
$$;

create or replace function public.homework_grading_lock_release_v1(
  p_academy_id uuid,
  p_target_key text,
  p_session_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.homework_grading_edit_locks l
  where l.academy_id = p_academy_id
    and l.target_key = p_target_key
    and l.owner_user_id = auth.uid()
    and l.session_token = p_session_token;
  return found;
end;
$$;

-- Updated clients commit through this wrapper. The same lease acquired when
-- the sheet opened must still be alive; a successful return releases it in
-- the same transaction.
create or replace function public.homework_commit_structured_grading_return_v3(
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id uuid := nullif(p_payload->>'request_id', '')::uuid;
  v_group_id uuid := nullif(p_payload->>'group_id', '')::uuid;
  v_lock_token uuid := nullif(p_payload->>'grading_lock_token', '')::uuid;
  v_academy_id uuid;
  v_target_key text;
  v_result jsonb;
begin
  if v_request_id is null or v_group_id is null or v_lock_token is null then
    raise exception 'HOMEWORK_GRADING_LOCK_REQUIRED';
  end if;

  select g.academy_id
  into v_academy_id
  from public.homework_groups g
  where g.id = v_group_id;
  v_target_key := 'group:' || v_group_id::text;

  -- A successful commit whose response was lost remains safely idempotent
  -- even though that transaction already released its lease.
  if exists (
    select 1
    from public.homework_test_grading_attempts a
    where a.id = v_request_id
      and a.academy_id = v_academy_id
      and a.graded_by = auth.uid()
  ) then
    return jsonb_build_object(
      'ok', true,
      'duplicate', true,
      'request_id', v_request_id
    );
  end if;

  if not exists (
    select 1
    from public.homework_grading_edit_locks l
    where l.academy_id = v_academy_id
      and l.target_key = v_target_key
      and l.owner_user_id = auth.uid()
      and l.session_token = v_lock_token
      and l.expires_at > now()
  ) then
    raise exception 'HOMEWORK_GRADING_LOCK_LOST';
  end if;

  v_result := public.homework_commit_structured_grading_return_v2(p_payload);

  delete from public.homework_grading_edit_locks l
  where l.academy_id = v_academy_id
    and l.target_key = v_target_key
    and l.owner_user_id = auth.uid()
    and l.session_token = v_lock_token;

  return v_result;
end;
$$;

revoke all on function public.homework_grading_lock_acquire_v1(
  uuid, uuid, uuid, uuid[], uuid, integer
) from public;
revoke all on function public.homework_grading_lock_heartbeat_v1(
  uuid, text, uuid, integer
) from public;
revoke all on function public.homework_grading_lock_release_v1(
  uuid, text, uuid
) from public;
revoke all on function public.homework_commit_structured_grading_return_v3(
  jsonb
) from public;

grant execute on function public.homework_grading_lock_acquire_v1(
  uuid, uuid, uuid, uuid[], uuid, integer
) to authenticated;
grant execute on function public.homework_grading_lock_heartbeat_v1(
  uuid, text, uuid, integer
) to authenticated;
grant execute on function public.homework_grading_lock_release_v1(
  uuid, text, uuid
) to authenticated;
grant execute on function public.homework_commit_structured_grading_return_v3(
  jsonb
) to authenticated;
