-- Student archives (1-year retention)
-- Purpose: Keep withdrawn (deleted) student info for a period without relying on local DB.
-- Flow (client):
--  1) call rpc archive_student(academy_id, student_id) to snapshot related rows into jsonb
--  2) call rpc delete_student(academy_id, student_id) to hard-delete the student (cascade)
--
-- Purge policy:
--  - Use a scheduled job (Supabase Scheduled Functions/cron) to delete rows where purge_after < now()

create table if not exists public.student_archives (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null,
  student_name text,
  payload jsonb not null,
  archived_at timestamptz not null default now(),
  archived_by uuid default auth.uid(),
  purge_after timestamptz not null
);

create index if not exists idx_student_archives_academy on public.student_archives(academy_id);
create index if not exists idx_student_archives_student on public.student_archives(academy_id, student_id);
create index if not exists idx_student_archives_purge_after on public.student_archives(academy_id, purge_after);
create index if not exists idx_student_archives_archived_at on public.student_archives(academy_id, archived_at desc);

alter table public.student_archives enable row level security;

drop policy if exists student_archives_all on public.student_archives;
create policy student_archives_all on public.student_archives for all
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = student_archives.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = student_archives.academy_id
      and m.user_id = auth.uid()
  )
);

-- RPC: archive a student into student_archives (jsonb snapshot)
create or replace function public.archive_student(
  p_academy_id uuid,
  p_student_id uuid
) returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_archive_id uuid;
  v_student_name text;
  v_payload jsonb;
begin
  -- Give it some room (similar to delete_student RPC).
  perform set_config('statement_timeout', '60s', true);

  select s.name into v_student_name
  from public.students s
  where s.academy_id = p_academy_id
    and s.id = p_student_id
  limit 1;

  if v_student_name is null then
    raise exception 'student not found (academy_id=%, student_id=%)', p_academy_id, p_student_id
      using errcode = 'P0002';
  end if;

  v_payload := jsonb_build_object(
    'students', (
      select to_jsonb(s)
      from public.students s
      where s.academy_id = p_academy_id and s.id = p_student_id
      limit 1
    ),
    'student_basic_info', (
      select to_jsonb(bi)
      from public.student_basic_info bi
      where bi.academy_id = p_academy_id and bi.student_id = p_student_id
      limit 1
    ),
    'student_payment_info', (
      select to_jsonb(spi)
      from public.student_payment_info spi
      where spi.academy_id = p_academy_id and spi.student_id = p_student_id
      limit 1
    ),
    'student_time_blocks', (
      select coalesce(jsonb_agg(to_jsonb(stb) order by stb.day_index asc, stb.start_hour asc, stb.start_minute asc), '[]'::jsonb)
      from public.student_time_blocks stb
      where stb.academy_id = p_academy_id and stb.student_id = p_student_id
    ),
    'attendance_records', (
      select coalesce(
        jsonb_agg(
          to_jsonb(ar)
          order by ar.date desc nulls last, ar.class_date_time desc nulls last, ar.created_at desc
        ),
        '[]'::jsonb
      )
      from public.attendance_records ar
      where ar.academy_id = p_academy_id and ar.student_id = p_student_id
    ),
    'payment_records', (
      select coalesce(
        jsonb_agg(
          to_jsonb(pr)
          order by pr.cycle desc nulls last, pr.due_date desc nulls last, pr.created_at desc
        ),
        '[]'::jsonb
      )
      from public.payment_records pr
      where pr.academy_id = p_academy_id and pr.student_id = p_student_id
    ),
    'session_overrides', (
      select coalesce(
        jsonb_agg(
          to_jsonb(so)
          order by so.created_at desc nulls last
        ),
        '[]'::jsonb
      )
      from public.session_overrides so
      where so.academy_id = p_academy_id and so.student_id = p_student_id
    ),
    'lesson_snapshot_headers', (
      select coalesce(
        jsonb_agg(to_jsonb(h) order by h.snapshot_at desc nulls last, h.created_at desc),
        '[]'::jsonb
      )
      from public.lesson_snapshot_headers h
      where h.academy_id = p_academy_id and h.student_id = p_student_id
    ),
    'lesson_snapshot_blocks', (
      select coalesce(
        jsonb_agg(to_jsonb(b) order by b.day_index asc, b.start_hour asc, b.start_minute asc),
        '[]'::jsonb
      )
      from public.lesson_snapshot_blocks b
      join public.lesson_snapshot_headers h on h.id = b.snapshot_id
      where h.academy_id = p_academy_id and h.student_id = p_student_id
    ),
    'lesson_batch_headers', (
      select coalesce(
        jsonb_agg(to_jsonb(bh) order by bh.created_at desc nulls last),
        '[]'::jsonb
      )
      from public.lesson_batch_headers bh
      where bh.academy_id = p_academy_id and bh.student_id = p_student_id
    ),
    'lesson_batch_sessions', (
      select coalesce(
        jsonb_agg(to_jsonb(bs) order by bs.created_at desc nulls last),
        '[]'::jsonb
      )
      from public.lesson_batch_sessions bs
      where bs.student_id = p_student_id
    ),
    'lesson_occurrences', (
      select coalesce(
        jsonb_agg(to_jsonb(o) order by o.cycle desc, o.session_order desc nulls last, o.created_at desc),
        '[]'::jsonb
      )
      from public.lesson_occurrences o
      where o.academy_id = p_academy_id and o.student_id = p_student_id
    )
  );

  insert into public.student_archives(
    academy_id,
    student_id,
    student_name,
    payload,
    purge_after
  )
  values (
    p_academy_id,
    p_student_id,
    v_student_name,
    v_payload,
    now() + interval '365 days'
  )
  returning id into v_archive_id;

  return v_archive_id;
end;
$$;

grant execute on function public.archive_student(uuid, uuid) to authenticated;

-- Optional helper RPC: purge expired archives in small batches.
-- Intended to be called by a scheduled job.
create or replace function public.purge_student_archives(
  p_limit integer default 1000
) returns integer
language plpgsql
set search_path = public
as $$
declare
  v_deleted integer;
begin
  perform set_config('statement_timeout', '60s', true);

  with doomed as (
    select sa.id
    from public.student_archives sa
    where sa.purge_after < now()
    order by sa.purge_after asc
    limit greatest(p_limit, 0)
  )
  delete from public.student_archives sa
  using doomed d
  where sa.id = d.id;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

grant execute on function public.purge_student_archives(integer) to authenticated;

