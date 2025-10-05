-- Unique constraint: one running homework per student (not completed)
do $$ begin
  execute 'create unique index if not exists ux_hw_running_per_student on public.homework_items(student_id) where run_start is not null and completed_at is null';
exception when others then null; end $$;

-- Start
create or replace function public.homework_start(p_item_id uuid, p_student_id uuid, p_academy_id uuid)
returns void
language plpgsql
security definer
set search_path = public as $$
begin
  perform 1 from public.homework_items h
    join public.students s on s.id = h.student_id
  where h.id = p_item_id and h.academy_id = p_academy_id and h.student_id = p_student_id;
  if not found then
    raise exception 'NOT_FOUND';
  end if;
  -- pause others
  update public.homework_items
    set accumulated_ms = coalesce(accumulated_ms,0) + extract(epoch from (now() - run_start))::bigint * 1000,
        run_start = null,
        updated_at = now(),
        version = version + 1
  where student_id = p_student_id and academy_id = p_academy_id and run_start is not null and completed_at is null;
  -- start target
  update public.homework_items
    set run_start = now(),
        first_started_at = coalesce(first_started_at, now()),
        status = 0,
        updated_at = now(),
        version = version + 1
  where id = p_item_id and academy_id = p_academy_id;
end$$;
revoke all on function public.homework_start(uuid,uuid,uuid) from public;
grant execute on function public.homework_start(uuid,uuid,uuid) to anon, authenticated;

-- Pause
create or replace function public.homework_pause(p_item_id uuid, p_academy_id uuid)
returns void
language plpgsql
security definer
set search_path = public as $$
begin
  update public.homework_items
    set accumulated_ms = coalesce(accumulated_ms,0) + extract(epoch from (now() - run_start))::bigint * 1000,
        run_start = null,
        updated_at = now(),
        version = version + 1
  where id = p_item_id and academy_id = p_academy_id and run_start is not null;
end$$;
revoke all on function public.homework_pause(uuid,uuid) from public;
grant execute on function public.homework_pause(uuid,uuid) to anon, authenticated;

-- Complete
create or replace function public.homework_complete(p_item_id uuid, p_academy_id uuid)
returns void
language plpgsql
security definer
set search_path = public as $$
begin
  update public.homework_items
    set accumulated_ms = coalesce(accumulated_ms,0) + case when run_start is not null then extract(epoch from (now() - run_start))::bigint * 1000 else 0 end,
        run_start = null,
        completed_at = now(),
        status = 1,
        updated_at = now(),
        version = version + 1
  where id = p_item_id and academy_id = p_academy_id;
end$$;
revoke all on function public.homework_complete(uuid,uuid) from public;
grant execute on function public.homework_complete(uuid,uuid) to anon, authenticated;


